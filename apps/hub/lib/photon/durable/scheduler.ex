defmodule Photon.Durable.Scheduler do
  @moduledoc """
  Runs durable tasks.

  After every commit that touches tasks or signals, and when a timer is due,
  it reconciles: tasks marked for abort are stopped, deepest first; waiting
  tasks whose condition holds become pending; pending tasks start, each step
  in its own process under `Photon.Durable.TaskSupervisor`. The rules are
  `Photon.Durable.Policy`; each decision is applied in its own commit,
  re-checking the task there. A task whose kind isn't registered stays
  pending until it is.

  A step that ends without a transition (or crashes) fails its task, unless
  the task was marked for abort, which then ends it as aborted; a kind's
  `on_fail/3` may ask for the phase to run again instead. When a
  conversation's run fails or is aborted, its queued input starts the next
  run.

  ## Process

  One per hub, under `Photon.Durable.Supervisor`. A crash loses only its
  view of the steps it started, its timer and its unknown-kind warnings.
  `init/1` puts `running` tasks back to `pending` (their phase runs again,
  with `runs` telling the step it is a retry) and reconciles. Steps keep
  running across a restart of this process alone (they aren't linked to
  it) and are fenced out of committing (`Photon.Durable.Tx.transition/4`).

  `notify/2`, which `Photon.Durable.Store` calls after a commit, is a plain
  send on purpose: the Store must never wait on the scheduler. It can't
  flood the mailbox: a burst of notifications collapses into one pending
  reconcile, and a reconcile reads the database rather than the messages,
  so a lost notification only delays work until the next commit or timer.
  """

  use GenServer

  require Logger

  alias Photon.Durable
  alias Photon.Durable.{Policy, Queries, Runtime, Store, TaskRecord, Tx}
  alias Photon.Repo

  defstruct running: %{},
            refs: %{},
            killed: MapSet.new(),
            timer: nil,
            scheduled: false,
            unknown: MapSet.new()

  @typedoc """
  The steps it started (task ID to step pid and monitor, and back), the
  steps it killed for an abort, its timer, whether a reconcile is queued,
  and the unregistered kinds it already warned about.
  """
  @type t :: %__MODULE__{
          running: %{String.t() => {pid(), reference()}},
          refs: %{reference() => String.t()},
          killed: MapSet.t(String.t()),
          timer: reference() | nil,
          scheduled: boolean(),
          unknown: MapSet.t(String.t())
        }

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  # The Store's notification after a commit; see the moduledoc.
  @spec notify([TaskRecord.t()], [String.t()]) :: :ok
  def notify(tasks, signals) do
    if pid = Process.whereis(__MODULE__), do: send(pid, {:changed, tasks, signals})
    :ok
  end

  @doc "Waits until every runnable task has been started (for tests)."
  @spec sync() :: :ok
  def sync, do: GenServer.call(__MODULE__, :sync)

  @doc false
  # Whether a waiting task's condition holds now; reads the facts it needs.
  @spec wake?(TaskRecord.t(), integer()) :: boolean()
  def wake?(%TaskRecord{waiting: waiting}, now), do: Policy.wake?(waiting, facts(waiting), now)

  @impl true
  def init(_opts) do
    {count, _} = Repo.update_all(Queries.running(), set: [status: "pending"])
    if count > 0, do: Logger.info("durable: resuming #{count} interrupted task step(s)")

    send(self(), :reconcile)
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call(:sync, _from, state), do: {:reply, :ok, reconcile(state)}

  @impl true
  def handle_info({:changed, _tasks, _signals}, state), do: {:noreply, schedule_reconcile(state)}

  def handle_info(:reconcile, state), do: {:noreply, reconcile(%{state | scheduled: false})}

  def handle_info(:timer, state), do: {:noreply, reconcile(%{state | timer: nil})}

  # A step finished. It should have committed a transition; if its task is
  # still running, it returned without one, which is a bug in the step.
  def handle_info({ref, _result}, state) when is_map_key(state.refs, ref) do
    Process.demonitor(ref, [:flush])
    {task_id, state} = forget(state, ref)
    fail_if_running(task_id, &Policy.no_transition/1)
    {:noreply, schedule_reconcile(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_map_key(state.refs, ref) do
    {task_id, state} = forget(state, ref)
    {:noreply, schedule_reconcile(step_down(state, task_id, reason))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A step this scheduler killed (its task is being aborted) is expected to
  # go down; any other exit is a crash that fails its task.
  defp step_down(state, task_id, reason) do
    if MapSet.member?(state.killed, task_id) do
      %{state | killed: MapSet.delete(state.killed, task_id)}
    else
      Logger.error("durable task #{task_id} crashed: #{Exception.format_exit(reason)}")
      fail_if_running(task_id, fn _task -> Policy.crash_reason(reason) end)
      state
    end
  end

  defp fail_if_running(task_id, reason) do
    case Repo.get(TaskRecord, task_id) do
      %TaskRecord{status: "running"} = task -> fail(task, reason.(task))
      _ -> :ok
    end
  end

  defp forget(state, ref) do
    {task_id, refs} = Map.pop(state.refs, ref)
    {task_id, %{state | refs: refs, running: Map.delete(state.running, task_id)}}
  end

  defp schedule_reconcile(%{scheduled: true} = state), do: state

  defp schedule_reconcile(state) do
    send(self(), :reconcile)
    %{state | scheduled: true}
  end

  ## Reconciling

  defp reconcile(state) do
    tasks = Repo.all(Queries.unfinished_tasks())

    state
    |> stop_aborted(tasks)
    |> wake_waiting(tasks)
    |> start_pending()
    |> arm_timer()
  end

  # Kill the steps of tasks marked for abort, then settle them bottom-up.
  defp stop_aborted(state, tasks) do
    state =
      tasks
      |> Policy.aborting()
      |> Policy.steps_to_kill(state.running)
      |> Enum.reduce(state, &kill_step/2)

    for task <- Policy.ready_to_abort(tasks), do: Store.commit(&abort_tx(&1, task.id))
    state
  end

  defp kill_step({task_id, {pid, _ref}}, state) do
    # :not_found means the step already ended; its :DOWN is ignored as killed.
    _ = Task.Supervisor.terminate_child(Durable.TaskSupervisor, pid)
    %{state | killed: MapSet.put(state.killed, task_id)}
  end

  defp abort_tx(tx, task_id) do
    fresh = Tx.get_task(tx, task_id)

    if Policy.abort?(fresh) do
      run_callback(fresh, :on_abort, [fresh, tx])
      aborted = Tx.update_task(tx, fresh, Policy.aborted())
      Durable.continue_inbox(tx, aborted)
    else
      :ok
    end
  end

  # The facts every waiting task needs are read together: two queries, not
  # two per task.
  defp wake_waiting(state, tasks) do
    now = System.system_time(:millisecond)
    waiting = Enum.filter(tasks, &Policy.wakeable?/1)
    facts = read_facts(waiting)

    for task <- waiting, Policy.wake?(task.waiting, facts.(task.waiting), now) do
      Store.commit(&wake_tx(&1, task.id))
    end

    state
  end

  # Returns a function giving the facts for one task's conditions.
  defp read_facts(waiting) do
    {ids, keys} = Policy.wanted(waiting)
    statuses = statuses(ids)
    recorded = keys |> Queries.recorded_signals() |> Repo.all() |> MapSet.new()
    &Policy.facts(&1, fn ids -> Map.take(statuses, ids) end, fn key -> key in recorded end)
  end

  defp wake_tx(tx, task_id) do
    fresh = Tx.get_task(tx, task_id)

    if Policy.wakeable?(fresh) do
      :ok = fail_fast(tx, fresh)
      Tx.update_task(tx, fresh, status: "pending")
    else
      :ok
    end
  end

  defp fail_fast(tx, %TaskRecord{waiting: waiting}) do
    case Policy.fail_fast_ids(waiting) do
      nil ->
        :ok

      ids ->
        waiting
        |> Policy.fail_fast_aborts(statuses(ids))
        |> Enum.map(&Tx.get_task(tx, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.each(&Tx.request_abort(tx, &1))
    end
  end

  defp facts(waiting), do: Policy.facts(waiting, &statuses/1, &signal_recorded?/1)

  defp statuses(ids), do: ids |> Queries.statuses() |> Repo.all() |> Map.new()

  defp signal_recorded?(key), do: Repo.get(Photon.Durable.Signal, key) != nil

  defp start_pending(state) do
    Enum.reduce(Repo.all(Queries.startable()), state, fn task, state ->
      case Policy.start_action(task, state.running, Durable.kind(task.kind), state.unknown) do
        :start -> start(state, task)
        :skip -> state
        :unknown_kind -> unknown_kind(state, task)
      end
    end)
  end

  defp unknown_kind(state, task) do
    Logger.warning("durable: no task kind #{inspect(task.kind)} is registered; #{task.id} waits")
    %{state | unknown: MapSet.put(state.unknown, task.kind)}
  end

  defp start(state, task) do
    case Store.commit(&start_tx(&1, task.id)) do
      %TaskRecord{} = task -> track(state, task, spawn_step(task))
      nil -> state
    end
  end

  defp start_tx(tx, task_id) do
    fresh = Tx.get_task(tx, task_id)
    if Policy.startable?(fresh), do: Tx.update_task(tx, fresh, Policy.start(fresh))
  end

  defp spawn_step(task) do
    module = Durable.kind(task.kind)
    runtime = %Runtime{task: task}

    Task.Supervisor.async_nolink(Durable.TaskSupervisor, fn ->
      Logger.metadata(durable_task: task.id)
      module.step(task.phase, task, runtime)
    end)
  end

  defp track(state, task, %Task{pid: pid, ref: ref}) do
    %{
      state
      | running: Map.put(state.running, task.id, {pid, ref}),
        refs: Map.put(state.refs, ref, task.id)
    }
  end

  # A task marked for abort is left to stop_aborted/2, which ends it as
  # aborted (its step returned after its transition was ignored).
  defp fail(task, reason), do: Store.commit(&fail_tx(&1, task.id, reason))

  defp fail_tx(tx, task_id, reason) do
    fresh = Tx.get_task(tx, task_id)

    if Policy.failable?(fresh) do
      fresh
      |> run_callback(:on_fail, [fresh, reason, tx])
      |> Policy.after_failure()
      |> settle_failure(tx, fresh, reason)
    else
      :ok
    end
  end

  defp settle_failure(:retry, tx, task, _reason), do: Tx.update_task(tx, task, status: "pending")

  defp settle_failure(:fail, tx, task, reason) do
    failed = Tx.finish(tx, task, "failed", Policy.failed_outcome(reason))
    Durable.continue_inbox(tx, failed)
  end

  # nil when the kind or callback is missing.
  defp run_callback(%TaskRecord{kind: kind}, callback, args) do
    module = Durable.kind(kind)

    if module && Durable.implements?(module, callback, length(args)),
      do: apply(module, callback, args)
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    # Whether it already fired doesn't matter: a reconcile is always safe.
    _ = Process.cancel_timer(timer)
    :ok
  end

  defp arm_timer(state) do
    :ok = cancel_timer(state.timer)

    conditions = Repo.all(Queries.waiting_conditions())

    case Policy.timer_delay(conditions, System.system_time(:millisecond)) do
      nil -> %{state | timer: nil}
      delay -> %{state | timer: Process.send_after(self(), :timer, delay)}
    end
  end
end
