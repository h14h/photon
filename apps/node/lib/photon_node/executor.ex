defmodule PhotonNode.Executor do
  @moduledoc """
  Runs the hub's operations on this node (`docs/plans/step-1-machine-tools.md`,
  section 2.3, node rules 1 to 9), and is the node's API for them:
  `start/1` (a parsed `op.start`), `cancel/1`, `ack/1` and `snapshots/0`
  (every journaled snapshot, for the hub link to send after each join).

  One process for all of the hub's operations. It owns the journal
  (`PhotonNode.Executor.Journal`): every write goes through it, so a cancel
  flag and a snapshot never overwrite each other. It starts operation
  processes with `PhotonNode.Harness.Ops.add/2` and owns them
  (`PhotonNode.Harness.Ops.Owner`): each reports its snapshots here, and
  each snapshot is fitted to the frame budget (`Request.fit/2`), journaled
  and then forwarded to the hub through `PhotonNode.Executor.Link`. A shell
  command's `process` checkpoint is answered only once it is journaled, and
  `:cancel` if the journal says canceled, so a command never spawns before
  its start is on disk (node rule 4). Live output goes straight from the
  operation process to the link, never through here.

  The decisions are pure: `PhotonNode.Executor.Request` judges an
  `op.start` and builds the answers for operations the node won't run, and
  `PhotonNode.Executor.Rules` says what `op.start`, the start-up scan and an
  operation process's exit mean. This module reads the journal and the
  operation registry, calls them, and does what they say (rule 71).

  A failed journal write never runs anything (node rule 8): a `ready` entry
  that can't be written is answered with `Request.unrecorded/2` and starts
  no process, and a `process` checkpoint that can't be written is
  `{:error, reason}`, which fails the operation. A later snapshot that
  can't be written is logged and forwarded anyway.

  An operation process never dies because of its owner. `checkpoint/2` and
  `report/2` call this process with no timeout and catch every exit,
  returning `:ignored` and `:down`. A call that waits on a busy executor (a
  journal scan, an fsync of a large image snapshot) just waits; one whose
  executor dies returns at once. This process never calls an operation
  process synchronously (`Ops.add/2` starts a child whose `init/1` returns
  at once, or sends `:resend`), so the wait can't deadlock.

  Lifecycle: started by `PhotonNode` after the operation supervisor and
  before the hub connection, `:permanent`. `init/1` returns at once;
  `handle_continue/2` scans the journal and resumes every unfinished
  operation (`Rules.on_scan/2`): one still running is asked to resend its
  snapshot, one that isn't is started again from its snapshot, and either
  is told to cancel when its entry says so. Finished ones wait for the next
  join and their `op.ack`. It monitors every operation process (rule 87)
  and applies `Rules.down/3` to each exit: a crash fails the operation,
  and a clean exit before a terminal snapshot restarts it once. A crash of
  this process loses its monitors and restart counts, which the scan
  rebuilds; the operation processes keep running and their calls return
  `:down` or `:ignored` meanwhile. Once a day (and at start-up) it sweeps
  the output of operations acknowledged more than 7 days ago.
  """

  # The executor: this API and server, its journal, its functional core
  # (`Request`, `Rules`) as strict sub-boundaries, and `Link`, the contract
  # the hub link implements.
  use Boundary,
    deps: [PhotonNode, PhotonNode.Config, PhotonNode.Harness, PhotonCore, Jason],
    exports: [Link]

  use GenServer

  @behaviour PhotonNode.Harness.Ops.Owner

  require Logger

  alias PhotonCore.Operation
  alias PhotonNode.Config
  alias PhotonNode.Executor.{Journal, Link, Request, Rules}
  alias PhotonNode.Harness.{Env, Ops}
  alias PhotonNode.Harness.Ops.Owner

  # The owner pair the executor's operations carry; there is one executor,
  # so its owner ID only says whose they are.
  @owner {__MODULE__, :hub}

  @max_age 7 * 24 * 60 * 60
  @sweep_ms 24 * 60 * 60 * 1000

  @enforce_keys [:facts]
  defstruct [:facts, monitors: %{}, restarted: MapSet.new()]

  @typedoc """
  The process state: what operations need to know about this node
  (`Request.facts/0`), the monitors of operation processes, and the
  operations restarted once after a clean exit.
  """
  @type t :: %__MODULE__{
          facts: Request.facts(),
          monitors: %{reference() => {String.t(), pid()}},
          restarted: MapSet.t(String.t())
        }

  ## API

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Handles a parsed `op.start` (`PhotonCore.Operation.Wire.parse_start/1`):
  runs a new operation once its `ready` entry is journaled, or sends the
  latest snapshot of one the node has, resuming it if nothing runs it, or
  answers with a `failed` snapshot (an unsupported kind, bad arguments, a
  journal write that failed, or an operation the hub has seen and the node
  has no record of). Returns once that is done; an executor that dies
  first makes it exit.
  """
  @spec start(Request.start()) :: :ok
  def start(start), do: GenServer.call(__MODULE__, {:start, start}, :infinity)

  @doc """
  Handles `op.cancel`: journals the cancel and tells the operation process.
  An operation the node has never seen is journaled as canceled before it
  started, and that snapshot is sent, so a later `op.start` runs nothing.
  A finished operation is left alone.
  """
  @spec cancel(String.t()) :: :ok
  def cancel(id), do: GenServer.call(__MODULE__, {:cancel, id}, :infinity)

  @doc """
  Handles `op.ack`: forgets a finished operation's entry, keeping its
  output files for the sweep. An unknown or unfinished operation is ignored.
  """
  @spec ack(String.t()) :: :ok
  def ack(id), do: GenServer.call(__MODULE__, {:ack, id}, :infinity)

  @doc "Every journaled snapshot, in ID order: what the hub link sends after each join."
  @spec snapshots() :: [Operation.t()]
  def snapshots, do: GenServer.call(__MODULE__, :snapshots, :infinity)

  ## Ops.Owner

  @doc """
  Journals an operation's checkpoint before it acts on it. `:cancel` if
  its entry says canceled, `:ignored` if it has no unfinished entry or the
  executor didn't answer (any exit), `{:error, reason}` if the write failed.
  """
  @impl Owner
  @spec checkpoint(term(), Operation.t()) :: :ok | :cancel | :ignored | {:error, String.t()}
  def checkpoint(_owner_id, op) do
    GenServer.call(__MODULE__, {:checkpoint, op}, :infinity)
  catch
    :exit, _ -> :ignored
  end

  @doc """
  Journals an operation's snapshot and forwards it. `:down` if the
  executor didn't take it (any exit); the operation resends it when the
  restarted executor asks.
  """
  @impl Owner
  @spec report(term(), Operation.t()) :: :ok | :down
  def report(_owner_id, op) do
    GenServer.call(__MODULE__, {:report, op}, :infinity)
  catch
    :exit, _ -> :down
  end

  @doc "Streams an operation's new output to the hub link, from the operation's own process."
  @impl Owner
  @spec output(term(), String.t(), String.t(), String.t()) :: :ok
  def output(_owner_id, op_id, stream, text), do: Link.output(op_id, stream, text)

  ## Server

  @impl true
  def init(nil) do
    config = PhotonNode.config()
    facts = %{shell: Env.shell(), ops_dir: Config.ops_dir(config), workspace: config.workspace}
    {:ok, %__MODULE__{facts: facts}, {:continue, :scan}}
  end

  @impl true
  def handle_continue(:scan, state) do
    state = Enum.reduce(Journal.list(state.facts.ops_dir), state, &scan/2)
    {:noreply, sweep(state)}
  end

  @impl true
  def handle_call({:start, start}, _from, state), do: {:reply, :ok, start_op(state, start)}
  def handle_call({:cancel, id}, _from, state), do: {:reply, :ok, cancel_op(state, id)}
  def handle_call({:ack, id}, _from, state), do: {:reply, :ok, ack_op(state, id)}
  def handle_call(:snapshots, _from, state), do: {:reply, journaled(state), state}
  def handle_call({:checkpoint, op}, _from, state), do: {:reply, checkpoint_op(state, op), state}
  def handle_call({:report, op}, _from, state), do: {:reply, :ok, report_op(state, op)}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state),
    do: {:noreply, down(state, ref, reason)}

  def handle_info(:sweep, state), do: {:noreply, sweep(state)}
  def handle_info(_message, state), do: {:noreply, state}

  ## op.start

  defp start_op(state, %{"id" => id, "known" => known} = start) do
    case Journal.read(ops_dir(state), id) do
      {:ok, entry} ->
        on_start(state, start, entry, Rules.on_start(entry, known, Ops.running?(id)))

      {:error, reason} ->
        start_unreadable(state, start, reason)
    end
  end

  defp on_start(state, start, _entry, :run), do: run(state, start)

  defp on_start(state, start, _entry, :lost),
    do: answer(state, Request.lost(start["id"], start["kind"]))

  defp on_start(state, _start, entry, {:resend, cancel?}) do
    :ok = Link.snapshot(entry["op"])
    if cancel?, do: Ops.cancel(entry["op"]["id"])
    state
  end

  defp on_start(state, _start, entry, {:resume, cancel?}) do
    :ok = Link.snapshot(entry["op"])
    revive(state, entry, cancel?)
  end

  defp run(state, start) do
    case Request.operation(start, state.facts) do
      {:ok, op} -> run_journaled(state, op)
      {:error, reason} -> answer(state, Request.rejected(start, reason))
    end
  end

  # Node rules 1 and 8: nothing runs before its `ready` entry is on disk.
  defp run_journaled(state, op) do
    case journal(state, op, false) do
      {:ok, op} ->
        :ok = Link.snapshot(op)
        revive(state, entry(op, false), false)

      {{:error, reason}, _op} ->
        answer(state, Request.unrecorded(op, reason))
    end
  end

  # An entry that exists but can't be read: an operation still running
  # replaces it with its next snapshot; otherwise the node can't tell what
  # happened, and says so rather than run it again.
  defp start_unreadable(state, %{"id" => id} = start, reason) do
    Logger.error("operation #{id}'s journal entry can't be read: #{reason}")
    if Ops.running?(id), do: state, else: answer(state, Request.unreadable(start, reason))
  end

  ## op.cancel

  defp cancel_op(state, id) do
    case Journal.read(ops_dir(state), id) do
      {:ok, nil} ->
        cancel_unstarted(state, id)

      {:ok, %{"op" => op} = entry} ->
        if Operation.terminal?(op), do: state, else: cancel_unfinished(state, entry)

      {:error, reason} ->
        log_unjournaled(state, id, "its cancel is only sent to the process", reason)
        :ok = Ops.cancel(id)
        state
    end
  end

  # Node rule 7: journaled, so an `op.start` that comes later gets this
  # snapshot back and runs nothing. Unjournaled, it isn't answered: the hub
  # sends the cancel again on its next join.
  defp cancel_unstarted(state, id) do
    case journal(state, Request.never_started(id), true) do
      {:ok, op} -> answer(state, op)
      {{:error, reason}, _op} -> log_unjournaled(state, id, "its cancel isn't answered", reason)
    end
  end

  defp cancel_unfinished(state, %{"op" => %{"id" => id}} = entry) do
    entry = %{entry | "cancel" => true}

    with {:error, reason} <- Journal.write(ops_dir(state), id, entry),
         do: log_unjournaled(state, id, "it is canceled without a record", reason)

    case Rules.on_scan(entry, Ops.running?(id)) do
      {:resume, cancel?} ->
        revive(state, entry, cancel?)

      {:resend, _cancel?} ->
        :ok = Ops.cancel(id)
        state
    end
  end

  ## op.ack

  # Node rule 6. An unreadable entry was answered with a failed snapshot
  # (unless a process runs it), and the hub has recorded that.
  defp ack_op(state, id) do
    case Journal.read(ops_dir(state), id) do
      {:ok, nil} -> state
      {:ok, %{"op" => op}} -> if Operation.terminal?(op), do: forget(state, id), else: state
      {:error, _reason} -> if Ops.running?(id), do: state, else: forget(state, id)
    end
  end

  defp forget(state, id) do
    with {:error, reason} <- Journal.forget(ops_dir(state), id),
         do: Logger.warning("couldn't forget operation #{id}: #{reason}")

    %{state | restarted: MapSet.delete(state.restarted, id)}
  end

  ## Owner callbacks

  # Node rule 4: the command spawns only once this is journaled, and only
  # if the journal doesn't say canceled.
  defp checkpoint_op(state, %{"id" => id} = op) do
    case Journal.read(ops_dir(state), id) do
      {:ok, %{"op" => journaled, "cancel" => cancel}} -> confirm(state, op, journaled, cancel)
      {:ok, nil} -> :ignored
      {:error, reason} -> {:error, reason}
    end
  end

  defp confirm(state, op, journaled, cancel) do
    cond do
      Operation.terminal?(journaled) -> :ignored
      cancel -> :cancel
      true -> confirm_journaled(journal(state, op, false))
    end
  end

  defp confirm_journaled({:ok, op}), do: Link.snapshot(op)
  defp confirm_journaled({{:error, reason}, _op}), do: {:error, reason}

  # A snapshot after a finished one (nothing should send one) changes
  # nothing, so the journal keeps the result.
  defp report_op(state, %{"id" => id} = op) do
    case Journal.read(ops_dir(state), id) do
      {:ok, %{"op" => journaled, "cancel" => cancel}} ->
        if Operation.terminal?(journaled), do: state, else: record(state, op, cancel)

      {:ok, nil} ->
        Logger.warning("ignoring a snapshot of operation #{id}, which has no journal entry")
        state

      {:error, reason} ->
        log_unjournaled(state, id, "its snapshot is forwarded anyway", reason)
        answer(state, op)
    end
  end

  ## Operation processes

  # Starts an operation from its entry, or asks the process that runs it
  # to resend its snapshot (`Ops.add/2` does whichever applies), monitors
  # it, and tells it to cancel when `cancel?` (node rule 2).
  defp revive(state, %{"op" => op} = entry, cancel?) do
    case Ops.add(op, @owner) do
      {:ok, pid} ->
        if cancel?, do: Ops.cancel(op["id"])
        watch(state, op["id"], pid)

      {:error, reason} ->
        message = "photon-node couldn't start the operation: #{reason_text(reason)}"
        record(state, Request.failed(op, message), entry["cancel"])
    end
  end

  defp scan(entry, state) do
    case Rules.on_scan(entry, Ops.running?(entry["op"]["id"])) do
      :skip -> state
      {_resend_or_resume, cancel?} -> revive(state, entry, cancel?)
    end
  end

  defp watch(state, id, pid) do
    if Enum.any?(state.monitors, fn {_ref, watched} -> watched == {id, pid} end),
      do: state,
      else: %{state | monitors: Map.put(state.monitors, Process.monitor(pid), {id, pid})}
  end

  # An exit of a process that has been replaced (its operation is
  # monitored again under a newer process) means nothing.
  defp down(state, ref, reason) do
    case Map.pop(state.monitors, ref) do
      {{id, _pid}, monitors} ->
        state = %{state | monitors: monitors}
        if watched?(state, id), do: state, else: exited(state, id, reason)

      {nil, _monitors} ->
        state
    end
  end

  defp watched?(state, id), do: Enum.any?(state.monitors, &match?({_ref, {^id, _pid}}, &1))

  defp exited(state, id, reason) do
    entry = readable_entry(state, id)

    case Rules.down(entry, reason, MapSet.member?(state.restarted, id)) do
      :ignore ->
        state

      {:restart, cancel?} ->
        revive(%{state | restarted: MapSet.put(state.restarted, id)}, entry, cancel?)

      {:fail, message} ->
        record(state, Request.failed(entry["op"], message), entry["cancel"])
    end
  end

  defp readable_entry(state, id) do
    case Journal.read(ops_dir(state), id) do
      {:ok, entry} ->
        entry

      {:error, reason} ->
        Logger.error("operation #{id} exited and its journal entry can't be read: #{reason}")
        nil
    end
  end

  ## Journal

  defp journaled(state), do: state |> ops_dir() |> Journal.list() |> Enum.map(& &1["op"])

  # Node rule 9: fitted to the frame budget, then journaled. Returns the
  # write's result and the fitted snapshot.
  defp journal(state, op, cancel) do
    op = Request.fit(op, Request.snapshot_budget())
    {Journal.write(ops_dir(state), op["id"], entry(op, cancel)), op}
  end

  # Node rules 5 and 8: journaled, then forwarded; a snapshot that can't be
  # journaled is forwarded anyway, and the journal keeps the older one.
  defp record(state, op, cancel) do
    case journal(state, op, cancel) do
      {:ok, op} ->
        answer(state, op)

      {{:error, reason}, op} ->
        log_unjournaled(state, op["id"], "its snapshot is forwarded anyway", reason)
        answer(state, op)
    end
  end

  defp entry(op, cancel), do: %{"op" => op, "cancel" => cancel}

  # Sends a snapshot to the hub.
  defp answer(state, op) do
    :ok = Link.snapshot(op)
    state
  end

  defp log_unjournaled(state, id, consequence, reason) do
    Logger.error("couldn't journal operation #{id}, so #{consequence}: #{reason}")
    state
  end

  defp sweep(state) do
    removed = Journal.sweep(ops_dir(state), System.os_time(:second), @max_age)

    if removed != [],
      do: Logger.info("swept the output of #{length(removed)} acknowledged operations")

    Process.send_after(self(), :sweep, @sweep_ms)
    state
  end

  defp ops_dir(state), do: state.facts.ops_dir

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)
end
