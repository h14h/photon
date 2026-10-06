defmodule PhotonNode.Harness.Coordinator do
  @moduledoc """
  The server that runs one session's state machine
  (`PhotonNode.Harness.Session`).

  Each callback hands its event to the session core, then runs the effects
  the core recorded, in order: appending records to the log
  (`PhotonNode.Harness.Store`) and announcing them to the hub
  (`PhotonNode.Harness.Link`), answering callers, starting and cancelling the
  model request (`PhotonNode.Harness.ModelRequest`) and operations
  (`PhotonNode.Harness.Ops`), and arming timers. Two things feed back into
  the core. An operation that can't be started fails
  (`Session.dispatch_failed/3`), and its effects run before the rest. And
  inputs and operation updates that arrive together are drained from the
  mailbox (`slurp/1`) and handed to the core one at a time, so they go
  into one decision. Each step's effects run before the next step starts,
  so a crash leaves a prefix of a handler's records in the log.

  Lifecycle: one coordinator per session, registered by session ID in
  `PhotonNode.SessionRegistry` and started on demand (`ensure_started/1`)
  under `PhotonNode.Harness.SessionSupervisor`. It is `:transient`: a crash
  restarts it, and it replays its log on start. It stops itself (`:normal`)
  after ten idle minutes, and the next input starts it again. A crash
  loses timers, the request in flight and mailbox messages. After replay,
  `Session.resume/1` and `Session.decide/1` start a new turn for work that
  was pending and re-arm the heartbeat and idle timers; a grace period
  isn't restored, so a turn it held back starts at once. Callers retry
  deliveries, which the inbox deduplicates.

  It traps exits. The model request task is linked, so it dies with the
  coordinator. Operation processes are monitored, and their `:DOWN` goes
  to `Session.op_down/3`.

  It owns its session's operations (`PhotonNode.Harness.Ops.Owner`, with
  the session ID as the owner ID): it starts them with
  `Ops.add(op, {Coordinator, session_id})` and implements the callbacks
  they report through. An operation process never dies because of its
  coordinator: `checkpoint/2` catches every exit and returns `:ignored`,
  and `report/2` and `output/4` are plain sends.

  Messages: deliveries and an operation's `process` checkpoint are calls,
  answered once the record is persisted. Operation snapshots (`report/2`)
  are plain sends, on purpose: the operation keeps its latest snapshot and
  `Ops.add/2` asks it to resend that snapshot when a restarted coordinator
  catches up, so a snapshot lost with a dead coordinator is recovered. Only
  an operation's own process sends them, a few per operation. Its live
  output (`output/4`) goes straight to the hub link as `op_output` data.
  """

  use GenServer, restart: :transient

  @behaviour PhotonNode.Harness.Ops.Owner

  require Logger

  alias PhotonCore.{LLM, Operation}
  alias PhotonNode.Config
  alias PhotonNode.Harness.{Env, Link, ModelRequest, Ops, Session, Skills, Store}
  alias PhotonNode.Harness.Ops.Owner

  @slurp_idle_ms 1
  @slurp_max 100
  @checkpoint_timeout 30_000
  @deliver_attempts 5
  @deliver_timeout 30_000

  @enforce_keys [:session, :store]
  defstruct [
    :session,
    :store,
    task: nil,
    grace: nil,
    heartbeat: nil,
    idle_timer: nil,
    op_monitors: %{}
  ]

  @typedoc """
  The process state: the session core plus what only the process holds,
  namely the open log, the model request task, timer references, and the
  monitors of operation processes.
  """
  @type t :: %__MODULE__{
          session: Session.t(),
          store: Store.t(),
          task: ModelRequest.t() | nil,
          grace: %{ref: reference(), timer: reference()} | nil,
          heartbeat: reference() | nil,
          idle_timer: reference() | nil,
          op_monitors: %{reference() => {String.t(), pid()}}
        }

  ## Client API

  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(session_id),
    do: GenServer.start_link(__MODULE__, session_id, name: via(session_id))

  @doc "The session's coordinator, if it is running."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(id) do
    case Registry.lookup(PhotonNode.SessionRegistry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Starts the session's coordinator unless it is running."
  @spec ensure_started(String.t()) :: {:ok, pid()} | {:error, String.t()}
  def ensure_started(id) do
    case DynamicSupervisor.start_child(PhotonNode.Harness.SessionSupervisor, {__MODULE__, id}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, "couldn't start session #{id}: #{inspect(reason)}"}
    end
  end

  @doc """
  Delivers an input (with the session's config, or `nil`) and returns once
  it is in the session's log, or known to be there already.

  A coordinator that dies first, by a crash or by stopping itself when
  idle, loses its mailbox, so the input goes to its successor instead (up
  to #{@deliver_attempts} attempts); the log's dedupe makes a repeat
  harmless. A delivery the coordinator hasn't confirmed after
  #{div(@deliver_timeout, 1000)} seconds (a hard stop is finishing, say)
  stays queued there and counts as delivered.
  """
  @spec deliver(String.t(), map() | nil, map()) :: :ok | {:error, String.t()}
  def deliver(id, config, input),
    do: call_with_retry(id, {:deliver, config, input}, @deliver_attempts)

  defp call_with_retry(id, message, attempts) do
    with {:ok, pid} <- ensure_started(id) do
      try do
        GenServer.call(pid, message, @deliver_timeout)
      catch
        :exit, {:timeout, _} ->
          Logger.warning("session #{id} hasn't confirmed a delivery yet; it stays queued there")
          :ok

        :exit, reason ->
          await_down(pid)
          retry(id, message, attempts - 1, reason)
      end
    end
  end

  defp retry(id, message, attempts, _reason) when attempts > 0,
    do: call_with_retry(id, message, attempts)

  defp retry(id, _message, _attempts, reason),
    do: {:error, "session #{id} isn't taking input: #{Exception.format_exit(reason)}"}

  defp await_down(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      1_000 -> Process.demonitor(ref, [:flush])
    end
  end

  @doc "Stops the session's coordinator, if it is running."
  @spec shutdown(String.t()) :: :ok
  def shutdown(id) do
    case whereis(id) do
      nil ->
        :ok

      pid ->
        # :not_found means it exited on its own meanwhile, which is the goal.
        _ = DynamicSupervisor.terminate_child(PhotonNode.Harness.SessionSupervisor, pid)
        :ok
    end
  end

  @doc "Reports an operation snapshot; dropped if the coordinator isn't running."
  @impl Owner
  @spec report(String.t(), Operation.t()) :: :ok
  def report(id, op) do
    if pid = whereis(id), do: send(pid, {:op_update, op})
    :ok
  end

  @doc """
  Has an operation's checkpoint persisted before the operation acts on it.
  Returns `:ok` once it is in the log, `:cancel` if a hard stop is under
  way (the operation should cancel instead), or `:ignored` if the session
  doesn't know the operation or has finished it, or no coordinator
  answered (any exit, so the operation never dies because of it).
  """
  @impl Owner
  @spec checkpoint(String.t(), Operation.t()) :: :ok | :cancel | :ignored
  def checkpoint(id, op) do
    GenServer.call(via(id), {:op_update, op}, @checkpoint_timeout)
  catch
    :exit, _ -> :ignored
  end

  @doc "Streams an operation's new output to the hub as the session's live `op_output` data."
  @impl Owner
  @spec output(String.t(), String.t(), String.t(), String.t()) :: :ok
  def output(id, op_id, stream, text),
    do: Link.live(id, %{"type" => "op_output", "op" => op_id, "stream" => stream, "text" => text})

  @doc "A summary of the session's state (`Session.info/1`), for status reports and tests."
  @spec info(String.t()) :: map()
  def info(id), do: GenServer.call(via(id), :info)

  defp via(id), do: {:via, Registry, {PhotonNode.SessionRegistry, id}}

  ## Startup and replay

  @impl true
  def init(id) do
    Process.flag(:trap_exit, true)
    Logger.metadata(session: id)

    case Store.open(id) do
      {:ok, store, [header | records]} ->
        config = header["data"]["config"] || %{}
        session = id |> Session.new(config, session_env(id, config)) |> Session.replay(records)
        {:ok, %__MODULE__{session: session, store: store}, {:continue, :start}}

      {:error, reason} ->
        {:stop, {:shutdown, reason}}
    end
  end

  # What the session core knows about this machine, read once.
  defp session_env(id, config) do
    node = PhotonNode.config()
    workspace = config["workspace"] || node.workspace
    :ok = ensure_workspace(workspace)

    %{
      workspace: workspace,
      shell: Env.shell(),
      operations_dir: Store.operations_dir(id),
      skills: Skills.discover(workspace),
      machine: "#{Config.hostname()} (#{:erlang.system_info(:system_architecture)})",
      heartbeat_ms: node.heartbeat_ms
    }
  end

  @impl true
  def handle_continue(:start, state) do
    state |> run(&Session.resume/1) |> decide() |> noreply()
  end

  ## Messages

  @impl true
  def handle_call(:info, _from, state), do: {:reply, Session.info(state.session), state}

  # deliver/3: answered once the input is persisted.
  def handle_call({:deliver, config, input}, from, state) do
    state |> run(&Session.deliver(&1, config, input, from)) |> slurp() |> decide() |> noreply()
  end

  # checkpoint/2: answered once the snapshot is persisted.
  def handle_call({:op_update, op}, from, state) do
    state |> run(&Session.op_update(&1, op, from)) |> slurp() |> decide() |> noreply()
  end

  @impl true
  def handle_info({:input, input}, state) do
    state |> run(&Session.deliver(&1, nil, input, nil)) |> slurp() |> decide() |> noreply()
  end

  def handle_info({:op_update, op}, state) do
    state |> run(&Session.op_update(&1, op, nil)) |> slurp() |> decide() |> noreply()
  end

  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    %{state | task: nil}
    |> run(&Session.model_response(&1, result))
    |> slurp()
    |> decide()
    |> noreply()
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}} = state) do
    error = LLM.Error.new(:transport, "model request crashed: #{Exception.format_exit(reason)}")

    %{state | task: nil}
    |> run(&Session.model_response(&1, {:error, error}))
    |> slurp()
    |> decide()
    |> noreply()
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.op_monitors, ref) do
    {{op_id, _pid}, monitors} = Map.pop(state.op_monitors, ref)

    %{state | op_monitors: monitors}
    |> run(&Session.op_down(&1, op_id, reason))
    |> slurp()
    |> decide()
    |> noreply()
  end

  def handle_info({:grace, ref}, %{grace: %{ref: ref}} = state) do
    %{state | grace: nil} |> run(&Session.grace_expired/1) |> decide() |> noreply()
  end

  def handle_info({:heartbeat, ref}, %{heartbeat: ref} = state) do
    %{state | heartbeat: nil} |> run(&Session.heartbeat_fired/1) |> decide() |> noreply()
  end

  def handle_info(:idle_stop, state) do
    if Session.idle?(state.session), do: {:stop, :normal, state}, else: {:noreply, state}
  end

  # Stale timers and task replies for superseded turns.
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    ModelRequest.cancel(state.task)
    Store.close(state.store)
  end

  defp noreply(state), do: {:noreply, state}

  defp decide(state), do: run(state, &Session.decide/1)

  # Inputs and operation updates that arrive together go into one decision:
  # drain the mailbox (inputs first, then updates) until it is quiet for a
  # millisecond or a source reaches its cap, then record completions.
  defp slurp(state) do
    state
    |> drain(:input, @slurp_max)
    |> drain(:op_update, @slurp_max)
    |> run(&Session.reconcile/1)
  end

  defp drain(state, _tag, 0), do: state

  defp drain(state, :input, n) do
    receive do
      {:input, input} ->
        state |> run(&Session.deliver(&1, nil, input, nil)) |> drain(:input, n - 1)

      {:"$gen_call", from, {:deliver, config, input}} ->
        state |> run(&Session.deliver(&1, config, input, from)) |> drain(:input, n - 1)
    after
      @slurp_idle_ms -> state
    end
  end

  defp drain(state, :op_update, n) do
    receive do
      {:op_update, op} ->
        state |> run(&Session.op_update(&1, op, nil)) |> drain(:op_update, n - 1)

      {:"$gen_call", from, {:op_update, op}} ->
        state |> run(&Session.op_update(&1, op, from)) |> drain(:op_update, n - 1)
    after
      @slurp_idle_ms -> state
    end
  end

  ## Running the session's effects

  # One step of the core, then its effects, in order.
  defp run(state, step) do
    {session, effects} = state.session |> step.() |> Session.take_effects()
    Enum.reduce(effects, %{state | session: session}, &execute/2)
  end

  defp execute({:persist, kind, data}, state) do
    {store, record} = Store.append(state.store, kind, data)
    Link.event(state.session.id, record["seq"], record)
    %{state | store: store}
  end

  defp execute({:reply, from, reply}, state) do
    GenServer.reply(from, reply)
    state
  end

  defp execute({:warn, message}, state) do
    Logger.warning(message)
    state
  end

  defp execute({:request, turn_id, request}, state),
    do: %{state | task: ModelRequest.start(state.session.id, turn_id, request)}

  defp execute(:cancel_request, state) do
    ModelRequest.cancel(state.task)
    %{state | task: nil}
  end

  defp execute({:dispatch, op}, state) do
    case Ops.add(op, {__MODULE__, state.session.id}) do
      {:ok, pid} -> monitor_op(state, op["id"], pid)
      {:error, reason} -> run(state, &Session.dispatch_failed(&1, op, to_string(reason)))
    end
  end

  defp execute({:cancel_op, op_id}, state) do
    Ops.cancel(op_id)
    state
  end

  defp execute({:arm_grace, ms}, state) do
    cancel_grace_timer(state.grace)
    ref = make_ref()
    %{state | grace: %{ref: ref, timer: Process.send_after(self(), {:grace, ref}, ms)}}
  end

  defp execute(:cancel_grace, state) do
    cancel_grace_timer(state.grace)
    %{state | grace: nil}
  end

  # A disarmed heartbeat's timer still fires; its reference no longer matches.
  defp execute({:arm_heartbeat, ms}, state) do
    ref = make_ref()
    Process.send_after(self(), {:heartbeat, ref}, ms)
    %{state | heartbeat: ref}
  end

  defp execute(:disarm_heartbeat, state), do: %{state | heartbeat: nil}

  defp execute({:arm_idle_stop, ms}, state) do
    cancel_idle_timer(state.idle_timer)
    %{state | idle_timer: Process.send_after(self(), :idle_stop, ms)}
  end

  defp execute(:disarm_idle_stop, state) do
    cancel_idle_timer(state.idle_timer)
    %{state | idle_timer: nil}
  end

  defp monitor_op(state, op_id, pid) do
    if Enum.any?(state.op_monitors, fn {_ref, monitored} -> monitored == {op_id, pid} end),
      do: state,
      else: %{state | op_monitors: Map.put(state.op_monitors, Process.monitor(pid), {op_id, pid})}
  end

  defp cancel_grace_timer(nil), do: :ok
  defp cancel_grace_timer(%{timer: timer}), do: cancel_timer(timer)

  defp cancel_idle_timer(nil), do: :ok
  defp cancel_idle_timer(timer), do: cancel_timer(timer)

  defp cancel_timer(timer) do
    # Whether it already fired doesn't matter: a grace timeout carries its
    # reference, and an idle stop checks the session is still idle.
    _ = Process.cancel_timer(timer)
    :ok
  end

  # Commands run in the workspace, so a missing one makes each of them fail
  # with its own error; say why once, here.
  defp ensure_workspace(workspace) do
    case File.mkdir_p(workspace) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("couldn't create workspace #{workspace}: #{:file.format_error(reason)}")
    end
  end
end
