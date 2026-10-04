defmodule Photon.Durable.Policy do
  @moduledoc """
  The scheduler's rules, as pure functions of tasks and the facts the
  scheduler reads for them. `Photon.Durable.Scheduler` gathers the facts,
  asks these functions, and applies each answer in its own commit, where it
  re-reads the task and asks again (the `*?/1` predicates on a fresh task),
  since other commits can land in between.

  The rules:

    * stopping: a task marked for abort has its step killed if this
      scheduler runs one; it is aborted once no unfinished foreground task
      it owns is left, so trees stop bottom-up
    * waking: a waiting task wakes when any of its conditions holds (`"on"`
      tasks all finished, or one failed under `"fail_fast"`; its `"signal"`
      recorded; its `"until"` passed), or when it waits on nothing. Under
      `"fail_fast"`, waking aborts the unfinished rest
    * starting: a pending task that isn't marked for abort starts unless a
      step for it is already running here or its kind isn't registered
    * failing: a step that ended without a transition, or crashed, fails its
      running task unless it is marked for abort (then it ends aborted), or
      the kind's `on_fail/3` asks for a retry
    * the timer: one, for the earliest `"until"` among waiting tasks,
      capped at an hour
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [Photon.Durable.TaskRecord]

  alias Photon.Durable.TaskRecord

  @failed ~w(failed aborted)
  @max_timer_ms 3_600_000
  @timer_slack_ms 5

  @typedoc """
  What `wake?/3` needs to know beyond the task: the statuses of the tasks it
  waits on (`nil` when it waits on none) and whether its signal is recorded
  (`nil` when it waits on none).
  """
  @type facts :: %{statuses: %{String.t() => String.t()} | nil, signal?: boolean() | nil}

  @typedoc "The scheduler's running steps: task ID to whatever it tracks per step."
  @type running :: %{optional(String.t()) => term()}

  ## Stopping

  @doc "Tasks marked for abort."
  @spec aborting([TaskRecord.t()]) :: [TaskRecord.t()]
  def aborting(tasks), do: Enum.filter(tasks, & &1.abort_requested)

  @doc "The aborting tasks whose step runs here, so the scheduler kills it."
  @spec steps_to_kill([TaskRecord.t()], running()) :: [{String.t(), term()}]
  def steps_to_kill(aborting, running) do
    for task <- aborting, Map.has_key?(running, task.id), do: {task.id, running[task.id]}
  end

  @doc """
  The aborting tasks that can be aborted now: no unfinished foreground task
  among `tasks` (every unfinished task) names them as owner.
  """
  @spec ready_to_abort([TaskRecord.t()]) :: [TaskRecord.t()]
  def ready_to_abort(tasks) do
    blocked = owners_with_live_foreground_work(tasks)
    for task <- aborting(tasks), not MapSet.member?(blocked, task.id), do: task
  end

  defp owners_with_live_foreground_work(tasks) do
    for task <- tasks, not task.background, task.owner_task_id != nil, into: MapSet.new() do
      task.owner_task_id
    end
  end

  @doc "Whether a task re-read inside the abort commit still needs aborting."
  @spec abort?(TaskRecord.t() | nil) :: boolean()
  def abort?(%TaskRecord{} = task), do: not TaskRecord.terminal?(task)
  def abort?(nil), do: false

  @doc "The changes that end a task as aborted."
  @spec aborted() :: keyword()
  def aborted, do: [status: "aborted", outcome: %{"status" => "aborted"}, waiting: nil]

  ## Waking

  @doc "Whether a task is one the scheduler may wake: waiting and not marked for abort."
  @spec wakeable?(TaskRecord.t() | nil) :: boolean()
  def wakeable?(%TaskRecord{status: "waiting", abort_requested: false}), do: true
  def wakeable?(_task), do: false

  @doc """
  The facts `wake?/3` needs for `waiting`, read through `statuses` (task
  IDs to `%{id => status}`) and `signal?` (a key to whether it's recorded).
  Only the conditions `waiting` has are read.
  """
  @spec facts(map() | nil, ([String.t()] -> map()), (String.t() -> boolean())) :: facts()
  def facts(waiting, statuses, signal?) do
    waiting = waiting || %{}

    %{
      statuses: waiting["on"] && statuses.(waiting["on"]),
      signal?: waiting["signal"] && signal?.(waiting["signal"])
    }
  end

  @doc """
  What `tasks`' wait conditions name: the task IDs they wait on and their
  signal keys, each once, so their facts can be read in two queries however
  many tasks wait.
  """
  @spec wanted([TaskRecord.t()]) :: {[String.t()], [String.t()]}
  def wanted(tasks) do
    conditions = Enum.map(tasks, &(&1.waiting || %{}))

    {conditions |> Enum.flat_map(&(&1["on"] || [])) |> Enum.uniq(),
     conditions |> Enum.map(& &1["signal"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()}
  end

  @doc "Whether a waiting task's condition holds at `now` (Unix milliseconds)."
  @spec wake?(map() | nil, facts(), integer()) :: boolean()
  def wake?(waiting, facts, now) do
    waiting = waiting || %{}

    checks =
      Enum.reject(
        [
          waiting["on"] && on_ready?(waiting["on"], waiting["policy"], facts.statuses),
          waiting["signal"] && facts.signal?,
          waiting["until"] && now >= waiting["until"]
        ],
        &is_nil/1
      )

    checks == [] or Enum.any?(checks)
  end

  # A task that no longer exists counts as finished.
  defp on_ready?(ids, policy, statuses) do
    terminal = TaskRecord.terminal_statuses()

    Enum.all?(ids, &(Map.get(statuses, &1, "done") in terminal)) or
      (policy == "fail_fast" and any_failed?(statuses))
  end

  defp any_failed?(statuses), do: Enum.any?(statuses, fn {_id, status} -> status in @failed end)

  @doc """
  Under `"fail_fast"`, once one of the tasks waited on failed or was
  aborted, the IDs of the ones still unfinished, to abort. Otherwise none.
  `statuses` is read inside the wake commit.
  """
  @spec fail_fast_aborts(map() | nil, %{String.t() => String.t()}) :: [String.t()]
  def fail_fast_aborts(%{"policy" => "fail_fast", "on" => _ids}, statuses) do
    if any_failed?(statuses),
      do: for({id, status} <- statuses, status not in TaskRecord.terminal_statuses(), do: id),
      else: []
  end

  def fail_fast_aborts(_waiting, _statuses), do: []

  @doc "The task IDs a `\"fail_fast\"` wait needs statuses for, or none."
  @spec fail_fast_ids(map() | nil) :: [String.t()] | nil
  def fail_fast_ids(%{"policy" => "fail_fast", "on" => ids}), do: ids
  def fail_fast_ids(_waiting), do: nil

  ## Starting

  @doc """
  What to do with a pending task: `:start` it, `:skip` it (a step runs
  here already, or its kind is unregistered and already reported), or
  `:unknown_kind` (unregistered, not reported yet; it waits).
  """
  @spec start_action(TaskRecord.t(), running(), module() | nil, MapSet.t(String.t())) ::
          :start | :skip | :unknown_kind
  def start_action(%TaskRecord{id: id}, running, _module, _unknown)
      when is_map_key(running, id),
      do: :skip

  def start_action(%TaskRecord{kind: kind}, _running, nil, unknown) do
    if MapSet.member?(unknown, kind), do: :skip, else: :unknown_kind
  end

  def start_action(%TaskRecord{}, _running, _module, _unknown), do: :start

  @doc "Whether a task re-read inside the start commit can still start."
  @spec startable?(TaskRecord.t() | nil) :: boolean()
  def startable?(%TaskRecord{status: "pending", abort_requested: false}), do: true
  def startable?(_task), do: false

  @doc "The changes that start a task's phase: running, one more run."
  @spec start(TaskRecord.t()) :: keyword()
  def start(%TaskRecord{runs: runs}), do: [status: "running", runs: runs + 1]

  ## Failing

  @doc """
  Whether a task re-read inside the fail commit should fail. One marked for
  abort is left for the abort pass, which ends it as aborted.
  """
  @spec failable?(TaskRecord.t() | nil) :: boolean()
  def failable?(%TaskRecord{status: "running", abort_requested: false}), do: true
  def failable?(_task), do: false

  @doc "What a failure does, given what the kind's `on_fail/3` returned."
  @spec after_failure(term()) :: :retry | :fail
  def after_failure(:retry), do: :retry
  def after_failure(_other), do: :fail

  @doc "The outcome a failed task records."
  @spec failed_outcome(String.t()) :: map()
  def failed_outcome(reason), do: %{"status" => "failed", "reason" => reason}

  @doc "Why a task failed when its step returned without committing a transition."
  @spec no_transition(TaskRecord.t()) :: String.t()
  def no_transition(%TaskRecord{phase: phase}),
    do: "the step for phase #{phase} ended without a transition"

  @doc "Why a task failed when its step crashed with `reason`."
  @spec crash_reason(term()) :: String.t()
  def crash_reason({exception, _stack}) when is_exception(exception),
    do: Exception.message(exception)

  def crash_reason(reason), do: Exception.format_exit(reason)

  ## The timer

  @doc """
  How long until the scheduler should look again, given what every waiting
  task waits on: the earliest `"until"`, at most an hour away, plus a few
  milliseconds so the deadline has passed. `nil` when nothing waits on time.
  """
  @spec timer_delay([map() | nil], integer()) :: non_neg_integer() | nil
  def timer_delay(conditions, now) do
    case for(%{"until" => until} when is_integer(until) <- conditions, do: until) do
      [] -> nil
      deadlines -> min(max(Enum.min(deadlines) - now, 0), @max_timer_ms) + @timer_slack_ms
    end
  end
end
