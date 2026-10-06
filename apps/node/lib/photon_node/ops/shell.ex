defmodule PhotonNode.Ops.Shell do
  @moduledoc """
  The `shell` operation: runs one command, in the workspace, in its own
  process group, with stdout and stderr going straight to files in
  `<operations dir>/<op id>/` and stdin from `/dev/null`.

  A small wrapper starts the command as a job-control background job (so it
  leads a new process group), writes its PID to `pid` and reports it, waits
  for it, and writes the exit status to `exit` in the same directory. When
  the command exits, the whole group gets SIGTERM, then SIGKILL after five
  seconds, so background children don't outlive it. There is no timeout.

  Snapshots go to the operation's owner (`PhotonNode.Ops.Owner`).
  Checkpoints: `awaiting` in phase `process` (files ready), then with the
  process group ID once started, phase `read` with the exit code, and
  finally `completed` with the bounded output. The command starts only once
  the owner has stored the `process` checkpoint (`Owner.checkpoint/2`
  returns `:ok`), so a crash before that point leaves a `ready` operation
  that never ran, and a command is started at most once. An owner that
  couldn't store it (`{:error, reason}`) fails the operation, and the
  command never runs. An owner that didn't answer (`:ignored`: the
  executor died during the call, maybe after storing it) stops this
  process without running the command, and first writes an `unstarted`
  file next to the output. A resume that finds the `process` checkpoint
  with no process group, no `pid` file and that marker knows the command
  never started, so it starts it as a `ready` operation would, through the
  checkpoint again. Every start removes the marker before its checkpoint
  is stored, and the owner syncs this directory when it stores it, so the
  marker can't outlive a start that may have spawned the command.

  On recovery after a node restart, a command that was killed by a cancel
  (a `canceled` file in its directory, see below) is canceled, and one
  killed because this process stopped (a `stopped` file) failed, whatever
  its `exit` file says. Otherwise a command whose `exit` file exists is
  finished normally; one still running is waited for (polled,
  since this process has no port to it); one the `unstarted` marker proves
  never started is started; and any other failed with its outcome unknown.
  A process group not yet checkpointed is read from the `pid` file, so a
  command started just before a crash is still waited for (or killed by a
  stop).

  A shell that stops while its command may run (its supervisor shuts it
  down when the node stops, or it crashes) kills the command's process
  group in `terminate/2`: whenever the port is open, and whenever its
  snapshot is still `awaiting` in phase `process` with a process group on
  record (in the snapshot or the `pid` file), so a shell that resumed
  after an abrupt crash kills the command whether it has reattached yet or
  crashed in recovery first. It first writes a `stopped` file next to the
  output, unless the command has already exited (its `exit` file is
  there, and the kill is only for children it left), so a resumed
  operation reports that photon-node stopped and killed the command.
  Without it, the wrapper, which is outside the killed group, records exit
  143 and recovery would report the command `completed` with partial
  output.

  A cancel writes a `canceled` file before it kills the group, for the
  same reason: if the executor or the node dies before the `canceled`
  snapshot is stored, the resumed operation finds the marker and reports
  the cancel instead of the exit 143. A cancel that arrives before the
  wrapper reports the PID kills the group as soon as it does.

  Killing a group doesn't block the process. After SIGTERM it polls the
  group with `Process.send_after/3`, backing off from 1 ms to 50 ms, and
  sends SIGKILL after five seconds. Messages that arrive meanwhile are
  postponed, the way `gen_statem` postpones events. Once the group is gone
  and the step that waited for it has run, they are handled in the order
  they arrived, so each sees the state it would have seen after a blocking
  wait. If that step stops the process, they are dropped, as they were
  before. Only `terminate/2` still waits in place for a kill under way,
  since shutdown can't take messages. It doesn't run the waiting step: the
  owner may be shut down first and couldn't take its report.

  While it runs, new output streams to the hub as live events (not stored),
  sampled once a second in chunks of at most 64 KB per stream.
  """

  use GenServer, restart: :temporary

  require Logger

  alias PhotonCore.{Operation, Output}
  alias PhotonNode.Ops
  alias PhotonNode.Ops.{Env, Owner}

  # Job control gives the command its own process group (pgid == pid).
  # bash honours `set -m` without a terminal; for shells that don't, setsid
  # starts a new session, which also leads a new group.
  @wrapper ~S"""
  set -m
  "$0" -c "$1" </dev/null >"$2" 2>"$3" &
  pid=$!
  echo "$pid" >"$5.tmp" && mv "$5.tmp" "$5"
  echo "pid $pid"
  wait "$pid"
  code=$?
  echo "$code" >"$4.tmp" && mv "$4.tmp" "$4"
  echo "exit $code"
  """

  @setsid_wrapper ~S"""
  setsid "$0" -c "$1" </dev/null >"$2" 2>"$3" &
  pid=$!
  echo "$pid" >"$5.tmp" && mv "$5.tmp" "$5"
  echo "pid $pid"
  wait "$pid"
  code=$?
  echo "$code" >"$4.tmp" && mv "$4.tmp" "$4"
  echo "exit $code"
  """

  # The files a start leaves besides its output (see prepare_files/1).
  @leftovers ~w(exit stopped canceled unstarted pid)

  @term_grace_ms 5_000
  @max_poll_backoff_ms 50
  @tick_ms 1_000
  @live_chunk 65_536

  @spec start_link({Operation.t(), Owner.t()}) :: GenServer.on_start()
  def start_link({op, owner}) do
    GenServer.start_link(__MODULE__, {op, owner}, name: Ops.via(op["id"]))
  end

  @impl true
  def init({op, owner}) do
    Process.flag(:trap_exit, true)
    # Log lines carry the operation ID (`config :logger` lists `:op`).
    Logger.metadata(op: op["id"])

    state = %{
      op: op,
      owner: owner,
      port: nil,
      exit_code: nil,
      canceled: false,
      live_offsets: %{out: 0, err: 0},
      killing: nil,
      postponed: []
    }

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, %{op: op} = state),
    do: start(state, op["status"], op["state"]["phase"])

  defp start(state, "ready", _phase), do: prepare(state)
  defp start(state, "awaiting", "process"), do: recover(state)
  defp start(state, "awaiting", "read"), do: finish(state, state.op["state"]["exit_code"])
  defp start(state, "awaiting", _phase), do: prepare(state)
  defp start(state, "canceling", _phase), do: cancel(state)
  defp start(state, _status, _phase), do: {:stop, :normal, state}

  ## Starting

  defp prepare(state) do
    case prepare_files(state.op) do
      :ok -> start_when_confirmed(state, process_checkpoint(state.op))
      {:error, reason} -> fail(state, "prepare output files: #{:file.format_error(reason)}")
    end
  end

  # Empty output files only this user can read, and no exit, pid, stopped,
  # canceled or unstarted file left from an earlier start.
  defp prepare_files(op) do
    dir = dir(op)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         :ok <- File.write(out_path(op), "", [:write]),
         :ok <- File.write(err_path(op), "", [:write]),
         :ok <- File.chmod(out_path(op), 0o600),
         :ok <- File.chmod(err_path(op), 0o600) do
      remove_stale(dir, @leftovers)
    end
  end

  # A leftover exit, pid, stopped or canceled file would make recovery
  # think this start already ran, and a leftover unstarted file that it
  # never did, so one that can't be removed fails the operation.
  defp remove_stale(dir, names) do
    Enum.reduce_while(names, :ok, fn name, :ok ->
      case File.rm(Path.join(dir, name)) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp process_checkpoint(op) do
    Operation.advance(op, "awaiting", %{
      "phase" => "process",
      "out_path" => out_path(op),
      "err_path" => err_path(op)
    })
  end

  defp start_when_confirmed(state, op) do
    case Owner.checkpoint(state.owner, op) do
      :ok ->
        spawn_command(%{state | op: op})

      :cancel ->
        cancel(state)

      {:error, reason} ->
        fail(state, "couldn't record the command's start, so it didn't run: #{reason}")

      # Not confirmed: never start the command. The owner starts the
      # operation again from what it has on record, which may be this
      # checkpoint; the marker says the command never started.
      :ignored ->
        mark_unstarted(op)
        {:stop, :normal, state}
    end
  end

  defp spawn_command(state) do
    input = state.op["state"]["input"]
    {exe, script} = wrapper()

    args = [
      "-c",
      script,
      input["shell"],
      input["command"],
      out_path(state.op),
      err_path(state.op),
      exit_path(state.op),
      pid_path(state.op)
    ]

    try do
      port =
        Port.open({:spawn_executable, exe}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:line, 4096},
          {:args, args},
          {:cd, input["directory"]},
          {:env, Env.to_port(Env.overrides())}
        ])

      Process.send_after(self(), :tick, @tick_ms)
      {:noreply, %{state | port: port}}
    rescue
      e -> fail(state, "start process #{inspect(input["shell"])}: #{Exception.message(e)}")
    end
  end

  defp wrapper do
    cond do
      File.exists?("/bin/bash") -> {"/bin/bash", @wrapper}
      bash = System.find_executable("bash") -> {bash, @wrapper}
      System.find_executable("setsid") -> {"/bin/sh", @setsid_wrapper}
      true -> {"/bin/sh", @wrapper}
    end
  end

  ## Running

  @impl true
  def handle_info({:group_poll, ref}, %{killing: %{ref: ref} = killing} = state),
    do: await_group_exit(%{state | killing: nil}, killing)

  def handle_info(message, %{killing: %{}} = state),
    do: {:noreply, %{state | postponed: [message | state.postponed]}}

  def handle_info({port, {:data, {:eol, "pid " <> pid}}}, %{port: port} = state) do
    case Integer.parse(pid) do
      {pgid, ""} -> state |> checkpoint("awaiting", %{"pgid" => pgid}) |> kill_if_canceled(pgid)
      _ -> {:noreply, state}
    end
  end

  def handle_info({port, {:data, {:eol, "exit " <> code}}}, %{port: port} = state) do
    case Integer.parse(code) do
      {code, ""} -> {:noreply, %{state | exit_code: code}}
      _ -> {:noreply, state}
    end
  end

  def handle_info({port, {:data, _other}}, %{port: port} = state), do: {:noreply, state}

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    state = %{state | port: nil}
    stream_live(state)
    kill_group(state, state.op["state"]["pgid"], &exited(&1, status))
  end

  def handle_info(:tick, %{port: nil} = state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = stream_live(state)
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, state}
  end

  def handle_info(:poll, state), do: poll_recovered(state)

  def handle_info(:resend, state) do
    report(state.owner, state.op)
    {:noreply, state}
  end

  def handle_info(:cancel, %{port: nil} = state) do
    if Operation.terminal?(state.op), do: {:noreply, state}, else: cancel(state)
  end

  # The group is killed here (or once its PID is known, by
  # kill_if_canceled/2), after the canceled marker; the exit status arrives
  # next and finishes as canceled.
  def handle_info(:cancel, state) do
    mark_canceled(state.op)
    kill_group(state, state.op["state"]["pgid"], &{:noreply, %{&1 | canceled: true}})
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  # A command that may be running is killed, after the stopped marker: one
  # this process started (the port is open), or one on record for a
  # snapshot still awaiting its process, which a shell resumed after an
  # abrupt crash may be waiting for or may not have reattached to yet
  # (node rule 10, and no command left running after its op fails).
  @impl true
  def terminate(_reason, %{port: port} = state) when port != nil,
    do: stop_command(state, recorded_pgid(state.op))

  def terminate(
        _reason,
        %{op: %{"status" => "awaiting", "state" => %{"phase" => "process"}}} = state
      ) do
    case recorded_pgid(state.op) do
      nil -> await_kill_now(state)
      pgid -> stop_command(state, pgid)
    end
  end

  def terminate(_reason, state), do: await_kill_now(state)

  # Once the command has exited, a kill is only for children it left, so
  # its exit file stands and no marker is written.
  defp stop_command(state, pgid) do
    if read_exit(state.op) == nil, do: mark_stopped(state.op)

    case state.killing do
      %{} -> await_kill_now(state)
      nil -> kill_group_now(pgid)
    end
  end

  defp await_kill_now(%{killing: %{} = killing}),
    do: await_group_exit_now(killing.pgid, killing.deadline, killing.backoff)

  defp await_kill_now(_state), do: :ok

  # Written before the group is signalled, so a resume can't find the
  # wrapper's exit 143 without it.
  defp mark_stopped(op), do: write_marker(op, stopped_path(op))

  # Written before a cancel's kill, so a resume reports the cancel, not the
  # wrapper's exit 143.
  defp mark_canceled(op), do: write_marker(op, canceled_path(op))

  # Written only by a start that never spawned. Without it, a resume
  # reports the outcome as unknown, which is safe.
  defp mark_unstarted(op), do: write_marker(op, unstarted_path(op))

  defp write_marker(op, path) do
    case File.write(path, "") do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("shell #{op["id"]}: couldn't write #{path}: #{:file.format_error(reason)}")
    end
  end

  # Canceled before the PID was known: kill it now.
  defp kill_if_canceled(%{canceled: true} = state, pgid),
    do: kill_group(state, pgid, &{:noreply, &1})

  defp kill_if_canceled(state, _pgid), do: {:noreply, state}

  defp exited(%{canceled: true} = state, _status), do: cancel(state)

  defp exited(%{exit_code: code} = state, _status) when is_integer(code),
    do: finish_read(state, code)

  defp exited(state, status) do
    message = "the shell wrapper exited with status #{status} before reporting the command's exit"
    fail(state, message)
  end

  ## Recovery

  defp recover(state) do
    pgid = recorded_pgid(state.op)

    state =
      if pgid && pgid != state.op["state"]["pgid"],
        do: checkpoint(state, "awaiting", %{"pgid" => pgid}),
        else: state

    # The markers come before the exit file: the wrapper records exit 143
    # for a command this process killed for a cancel or as it stopped. A
    # cancel's kill comes first if both happened.
    cond do
      File.exists?(canceled_path(state.op)) -> cancel(state)
      File.exists?(stopped_path(state.op)) -> stopped(state, pgid)
      true -> reattach(state, pgid)
    end
  end

  defp stopped(state, pgid),
    do: kill_group(state, pgid, &fail(&1, stopped_message(read_exit(&1.op))))

  defp reattach(state, pgid) do
    cond do
      # A start that never spawned left the marker: run it now, from the top.
      pgid in [nil, 0] and File.exists?(unstarted_path(state.op)) ->
        prepare(state)

      pgid in [nil, 0] ->
        fail(state, "shell execution outcome is unknown because process start was not recorded")

      code = read_exit(state.op) ->
        kill_group(state, pgid, &finish_read(&1, code))

      group_alive?(pgid) ->
        Logger.info("shell #{state.op["id"]}: reattaching to process group #{pgid}")
        Process.send_after(self(), :poll, @tick_ms)
        {:noreply, state}

      true ->
        fail(state, "shell execution was interrupted before an exit status was recorded")
    end
  end

  defp stopped_message(nil),
    do: "photon-node stopped while the command was running, so the command was killed."

  defp stopped_message(code), do: stopped_message(nil) <> " Its exit status was #{code}."

  defp recorded_pgid(op) do
    case op["state"]["pgid"] do
      pgid when pgid in [nil, 0] -> read_pid(op)
      pgid -> pgid
    end
  end

  defp poll_recovered(state) do
    pgid = state.op["state"]["pgid"]

    # The exit file comes first, as in recover/1: a command that exited can
    # leave background children in its group, which are killed, not waited for.
    cond do
      state.canceled or state.op["status"] != "awaiting" ->
        {:noreply, state}

      # The command has exited; a kill now is only for its leftover children.
      code = read_exit(state.op) ->
        kill_group(state, pgid, &finish_read(&1, code))

      group_alive?(pgid) ->
        state = stream_live(state)
        Process.send_after(self(), :poll, @tick_ms)
        {:noreply, state}

      true ->
        fail(state, "shell execution was interrupted before an exit status was recorded")
    end
  end

  defp read_pid(op) do
    with {:ok, body} <- File.read(pid_path(op)),
         {pid, _} when pid > 1 <- Integer.parse(String.trim(body)) do
      pid
    else
      _ -> nil
    end
  end

  defp read_exit(op) do
    with {:ok, body} <- File.read(exit_path(op)),
         {code, _} <- Integer.parse(String.trim(body)) do
      code
    else
      _ -> nil
    end
  end

  ## Finishing

  defp finish_read(state, code) do
    state
    |> checkpoint("awaiting", %{"phase" => "read", "exit_code" => code, "pgid" => 0})
    |> finish(code)
  end

  defp finish(state, code) do
    limit = state.op["max_output_length"] || Output.default_limit()

    with {:ok, out, out_size, out_truncated} <- bounded_file(out_path(state.op), limit),
         {:ok, err, err_size, err_truncated} <- bounded_file(err_path(state.op), limit) do
      result = %{
        "out" => out,
        "err" => err,
        "out_size" => out_size,
        "err_size" => err_size,
        "exit_code" => code
      }

      state =
        checkpoint(state, "completed", %{
          "phase" => "",
          "exit_code" => nil,
          "result" => result,
          "out_truncated" => out_truncated,
          "err_truncated" => err_truncated
        })

      {:stop, :normal, state}
    else
      {:error, message} -> fail(state, message)
    end
  end

  # A command that may have started is killed after the canceled marker.
  defp cancel(state) do
    if awaiting_process?(state.op), do: mark_canceled(state.op)

    kill_group(state, state.op["state"]["pgid"], fn state ->
      state =
        checkpoint(state, "canceled", %{
          "phase" => "",
          "pgid" => 0,
          "terminal_error" => "shell operation canceled"
        })

      {:stop, :normal, state}
    end)
  end

  defp fail(state, message) do
    limit = state.op["max_output_length"] || Output.default_limit()

    state =
      checkpoint(state, "failed", %{
        "phase" => "",
        "terminal_error" => Output.bound!(message, limit)
      })

    {:stop, :normal, state}
  end

  # A file's output bounded to `limit` code points, reading at most
  # limit*4 bytes of it: all of a small file, or its head and tail.
  defp bounded_file(path, limit) do
    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         {:ok, io} <- :file.open(path, [:read, :binary, :raw]) do
      try do
        {text, truncated} = bounded_text(io, size, limit, path)
        {:ok, text, size, truncated}
      after
        :file.close(io)
      end
    else
      {:error, reason} -> {:error, "read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp bounded_text(io, size, limit, path) when size <= limit * 4 do
    {:ok, data} = read_at(io, 0, size)
    Output.bound(data, limit, path)
  end

  defp bounded_text(io, size, limit, path) do
    tail_bytes = (limit - div(limit, 2)) * 4
    {:ok, head} = read_at(io, 0, limit * 4 - tail_bytes)
    {:ok, tail} = read_at(io, size - tail_bytes, tail_bytes)
    {Output.truncated(head, tail, size, limit, path), true}
  end

  defp read_at(_io, _offset, 0), do: {:ok, ""}

  defp read_at(io, offset, count) do
    case :file.pread(io, offset, count) do
      {:ok, data} -> {:ok, data}
      :eof -> {:ok, ""}
      error -> error
    end
  end

  ## Process groups

  # Signals the group and waits for it to exit without blocking (see the
  # moduledoc); `then` takes the state and returns the callback's result.
  defp kill_group(state, pgid, then) when is_integer(pgid) and pgid > 1 do
    signal(pgid, "TERM")
    await_group_exit(state, %{pgid: pgid, deadline: kill_deadline(), backoff: 1, then: then})
  end

  defp kill_group(state, _pgid, then), do: then.(state)

  defp await_group_exit(state, killing) do
    case group_status(killing.pgid, killing.deadline) do
      :gone ->
        group_gone(state, killing.then)

      :overdue ->
        signal(killing.pgid, "KILL")
        group_gone(state, killing.then)

      :alive ->
        ref = make_ref()
        Process.send_after(self(), {:group_poll, ref}, killing.backoff)
        backoff = min(killing.backoff * 2, @max_poll_backoff_ms)
        {:noreply, %{state | killing: Map.merge(killing, %{ref: ref, backoff: backoff})}}
    end
  end

  defp group_gone(state, then) do
    postponed = Enum.reverse(state.postponed)
    %{state | postponed: []} |> then.() |> handle_postponed(postponed)
  end

  # Postponed messages see the state the waiting step left; one that starts
  # another kill postpones the rest again, still in order.
  defp handle_postponed({:noreply, state}, [message | rest]),
    do: message |> handle_info(state) |> handle_postponed(rest)

  defp handle_postponed(result, _messages), do: result

  # terminate/2 can't take messages, so it waits in place.
  defp kill_group_now(pgid) when is_integer(pgid) and pgid > 1 do
    signal(pgid, "TERM")
    await_group_exit_now(pgid, kill_deadline(), 1)
  end

  defp kill_group_now(_pgid), do: :ok

  defp await_group_exit_now(pgid, deadline, backoff) do
    case group_status(pgid, deadline) do
      :gone ->
        :ok

      :overdue ->
        signal(pgid, "KILL")

      :alive ->
        Process.sleep(backoff)
        await_group_exit_now(pgid, deadline, min(backoff * 2, @max_poll_backoff_ms))
    end
  end

  defp kill_deadline, do: System.monotonic_time(:millisecond) + @term_grace_ms

  defp group_status(pgid, deadline) do
    cond do
      not group_alive?(pgid) -> :gone
      System.monotonic_time(:millisecond) >= deadline -> :overdue
      true -> :alive
    end
  end

  defp signal(pgid, sig) do
    # kill fails only when the group has already exited, which is the goal.
    _ = System.cmd("/bin/sh", ["-c", "kill -#{sig} -#{pgid} 2>/dev/null"])
    :ok
  end

  defp group_alive?(pgid) when is_integer(pgid) and pgid > 1 do
    match?({_, 0}, System.cmd("/bin/sh", ["-c", "kill -0 -#{pgid} 2>/dev/null"]))
  end

  defp group_alive?(_), do: false

  ## Snapshots and live output

  defp checkpoint(state, status, changes) do
    op = Operation.advance(state.op, status, changes)
    report(state.owner, op)
    %{state | op: op}
  end

  defp report(owner, op) do
    # :down means no owner took the snapshot. This process keeps it and
    # resends it when its owner asks (`Ops.add/2` sends :resend).
    _ = Owner.report(owner, op)
    :ok
  end

  defp stream_live(state) do
    Enum.reduce(
      [out: out_path(state.op), err: err_path(state.op)],
      state,
      &stream_new_output/2
    )
  end

  defp stream_new_output({stream, path}, state) do
    offset = state.live_offsets[stream]

    case read_new_output(path, offset) do
      {:ok, data} ->
        send_live_output(state, stream, data)
        put_in(state.live_offsets[stream], offset + byte_size(data))

      :none ->
        state
    end
  end

  # Up to @live_chunk bytes written to `path` past `offset`, or :none.
  defp read_new_output(path, offset) do
    with {:ok, %File.Stat{size: size}} when size > offset <- File.stat(path),
         {:ok, io} <- :file.open(path, [:read, :binary, :raw]) do
      {:ok, data} = read_at(io, offset, min(size - offset, @live_chunk))
      # A read-only handle: closing has nothing to flush.
      _ = :file.close(io)
      {:ok, data}
    else
      _ -> :none
    end
  end

  defp send_live_output(state, stream, data),
    do: Owner.output(state.owner, state.op["id"], to_string(stream), Output.sanitize(data))

  defp awaiting_process?(op),
    do: op["status"] == "awaiting" and op["state"]["phase"] == "process"

  defp dir(op), do: Path.join(op["state"]["base_directory"], op["id"])
  defp out_path(op), do: Path.join(dir(op), "out")
  defp err_path(op), do: Path.join(dir(op), "err")
  defp exit_path(op), do: Path.join(dir(op), "exit")
  defp pid_path(op), do: Path.join(dir(op), "pid")
  defp stopped_path(op), do: Path.join(dir(op), "stopped")
  defp canceled_path(op), do: Path.join(dir(op), "canceled")
  defp unstarted_path(op), do: Path.join(dir(op), "unstarted")
end
