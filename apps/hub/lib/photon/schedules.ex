defmodule Photon.Schedules do
  @moduledoc """
  Schedules (section 3 of `docs/plans/step-3-skills-and-schedules.md`):
  prompts that fire at set times. A project's schedules start a new
  thread in the project each time, or wake one of its threads; Blip's own
  schedules post into Blip's conversation. The owner manages a project's
  on its page, and Blip makes its own and projects' with its `schedule`
  tool. Threads
  have no schedule tools, since a schedule that starts threads would let
  a thread start threads.

  A schedule is a row (`Photon.Schedules.Schedule`: the definition and a
  summary of its last firing) and a durable routine task that waits for
  its next time and fires it (`Photon.Schedules.Routine`, the
  `"routine"` task kind). The task is only the timer: the next time and
  whether the schedule is waiting, done or stopped are read from it,
  never stored on the row (rule 15).

  Where a firing goes follows from the row (`Photon.Schedules.Rules.target/1`):
  Blip's conversation, one thread, or a new thread, each with
  `"[Scheduled] <prompt>"` as the message. A firing reads the row and the
  facts it needs and applies `Photon.Schedules.Rules.fire/2`'s decision
  in one commit, so the facts are current when the decision lands:

    * consent: a firing uses the owner's ChatGPT plan only when Settings
      allows scheduled work (or on the scripted model, which uses nobody's
      plan); otherwise it is skipped, with a notice in Blip's conversation
      or the thread
    * overlap: a new-thread schedule skips while the thread it last
      started is still running, and a prompt never queues behind one of
      its own, so a stuck thread doesn't pile up firings (rule 73)

  Every edit replaces the task and every delete retires it, in the same
  commit as the row's change. The fence is `Photon.Durable.Runtime.commit/2`:
  a firing step whose task was marked for abort, finished or restarted
  commits nothing, so a firing happens once and never after its schedule
  was edited or deleted (checked in TLA+, `specs/tla/Durable.md`). The
  replacement task arms at the first time the old one hadn't fired
  (`Photon.Schedules.Rules.arm/4` and `fired_through/3`), so an edit
  neither skips nor repeats a firing.

  Blip's `schedule` and `cancel_schedule` tools change Blip's own
  schedules and projects' inside the commits that record their results
  (`tool_schedule_tx/4`, `delete_tx/3`), so a tool call that runs again
  after a restart makes or removes nothing twice. A project schedule Blip
  makes is a row like the form's, with `created_by: "blip"`, and fires
  under the same consent. Each row Blip makes says why (`asked_by`), and
  every firing's source carries who made it and why, for the signals to
  Blip and the activity log.

  Every change and every firing announces `{:schedules_changed,
  project_id}` (nil for Blip's) on `"schedules"` after its commit.

  There is no process here: the rows and the durable tasks hold the
  state, the Scheduler wakes the tasks, and the Store's commit line
  orders the writes. A hub restart finds each task waiting for its time,
  as it finds any durable task.
  """

  use Boundary,
    deps: [
      Photon.Durable,
      Photon.Events,
      Photon.Projects,
      Photon.Repo,
      Photon.Settings,
      Photon.Threads,
      PhotonCore,
      Ecto
    ],
    exports: [Schedule]

  import Ecto.Query

  alias Photon.{Durable, Events, Projects, Repo, Settings, Threads}
  alias Photon.Durable.{TaskRecord, Tx}
  alias Photon.Projects.Project
  alias Photon.Schedules.{Routine, Rules, Schedule}

  @topic "schedules"

  @typedoc "Whose schedules: Blip's own, or a project's."
  @type scope :: :blip | {:project, String.t()}

  @typedoc """
  Where a schedule from Blip's `schedule` tool fires: Blip's conversation,
  or a project, waking one of its threads or (nil) starting a new thread
  each time.
  """
  @type tool_target :: {:blip, String.t()} | {:project, String.t(), String.t() | nil}

  @typedoc """
  How Blip's `schedule` call makes a schedule: why (`asked_by`, `"owner"`
  or `"blip"`), the call's request ID, and the clock it read (Unix
  milliseconds).
  """
  @type made :: %{asked_by: String.t(), request_id: String.t(), now: Rules.ms()}

  @typedoc """
  Where a schedule stands, read from its task: waiting for its next time,
  done (a one-off that fired), or stopped because its task failed, with
  the reason.
  """
  @type state :: :waiting | :done | {:stopped, String.t()}

  @typedoc """
  A schedule with its next time (nil unless it is waiting) and state;
  `id` is the schedule's, for the pages' streams.
  """
  @type listed :: %{
          id: String.t(),
          schedule: Schedule.t(),
          next_at: DateTime.t() | nil,
          state: state()
        }

  @typedoc "Form errors: each field's message (`Photon.Schedules.Rules.schedule/2`)."
  @type field_errors :: Rules.field_errors()

  ## Subscriptions

  @doc """
  Subscribes to `{:schedules_changed, project_id}` (nil for Blip's), sent
  after every change, firing, run-now and failure.
  """
  @spec subscribe() :: :ok
  def subscribe, do: Events.subscribe(@topic)

  ## Reading

  @doc """
  Blip's schedules, or a project's, each with its next time and state:
  by next time (those without one last), then oldest first. Two queries:
  the rows, then their tasks.
  """
  @spec list(scope()) :: [listed()]
  def list(scope) do
    schedules = scope |> in_scope() |> order_by([s], asc: s.inserted_at, asc: s.id) |> Repo.all()
    tasks = tasks(for s <- schedules, s.task_id, do: s.task_id)

    schedules
    |> Enum.map(&listed(&1, Map.get(tasks, &1.task_id)))
    |> Enum.sort_by(&next_order/1)
  end

  defp in_scope(:blip), do: where(Schedule, [s], is_nil(s.project_id))

  defp in_scope({:project, project_id}),
    do: where(Schedule, [s], s.project_id == ^project_id)

  defp tasks([]), do: %{}

  defp tasks(ids) do
    TaskRecord
    |> where([t], t.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  # Waiting ones by their next time, the rest after them; Enum.sort_by is
  # stable, so each group keeps the rows' order.
  defp next_order(%{next_at: nil}), do: {1, 0}
  defp next_order(%{next_at: next_at}), do: {0, DateTime.to_unix(next_at, :microsecond)}

  @doc "Schedule `id` with its next time and state, or nil."
  @spec get(String.t()) :: listed() | nil
  def get(id) do
    case Repo.get(Schedule, id) do
      nil -> nil
      schedule -> listed(schedule, schedule.task_id && Durable.task(schedule.task_id))
    end
  end

  @doc """
  The prompts of schedules `ids`, by ID; an ID with no schedule (a
  cancelled one is deleted) is left out. The activity page says which
  schedule asked with it.
  """
  @spec prompts([String.t()]) :: %{optional(String.t()) => String.t()}
  def prompts([]), do: %{}

  def prompts(ids) do
    Schedule
    |> where([s], s.id in ^ids)
    |> select([s], {s.id, s.prompt})
    |> Repo.all()
    |> Map.new()
  end

  defp listed(schedule, task) do
    {next_at, state} = state(task)
    %{id: schedule.id, schedule: schedule, next_at: next_at, state: state}
  end

  # The next time and state follow from the task (rule 15). A schedule
  # without a live task fired its one time, or was stopped.
  defp state(nil), do: {nil, :done}
  defp state(%TaskRecord{status: "done"}), do: {nil, :done}

  defp state(%TaskRecord{status: "failed", outcome: outcome}),
    do: {nil, {:stopped, (outcome || %{})["reason"] || "it failed"}}

  defp state(%TaskRecord{status: "aborted"}), do: {nil, {:stopped, "its timer was stopped"}}

  defp state(%TaskRecord{} = task) do
    next_at = task.checkpoint["next_at"] || task.input["first_at"]
    {next_at && Rules.datetime(next_at), :waiting}
  end

  @doc """
  Whether a firing may use the owner's ChatGPT plan: the scripted model
  uses nobody's, and otherwise Settings must allow scheduled work.
  Checked at every firing, so turning it off stops the next one; run-now
  doesn't ask, since the owner pressed the button.
  """
  @spec consent?() :: boolean()
  def consent? do
    Application.get_env(:photon, :mock_model, false) or Settings.scheduled_work?(Settings.load())
  end

  @doc """
  The schedule form's starting values at `now`: a one-off at the next
  whole hour that starts a new thread, with every day ready for when the
  owner picks Every. String keys, as the form sends them.
  """
  @spec new_params(DateTime.t()) :: %{String.t() => String.t()}
  def new_params(%DateTime{} = now) do
    %{
      "prompt" => "",
      "at" =>
        now |> DateTime.to_unix(:millisecond) |> Rules.next_hour() |> Rules.datetime() |> iso(),
      "repeat" => "once",
      "every" => "1",
      "unit" => "days",
      "target" => "new_thread"
    }
  end

  @doc """
  The schedule form's values for editing `schedule`, as `new_params/1`
  gives them for a new one: its prompt, its first time, Once or Every
  with the interval in its largest whole unit, and its thread or
  `"new_thread"`. A one-off keeps every day ready for when the owner
  picks Every.
  """
  @spec edit_params(Schedule.t()) :: %{String.t() => String.t()}
  def edit_params(%Schedule{} = schedule) do
    {every, unit} =
      if schedule.every_minutes, do: Rules.every_unit(schedule.every_minutes), else: {1, "days"}

    %{
      "prompt" => schedule.prompt,
      "at" => iso(schedule.first_at),
      "repeat" => if(schedule.every_minutes, do: "every", else: "once"),
      "every" => Integer.to_string(every),
      "unit" => unit,
      "target" => schedule.conversation_id || "new_thread"
    }
  end

  # A form's time: ISO 8601 in UTC to the second, which every browser's
  # Date parses (some refuse six fractional digits). The form's times are
  # whole minutes, so nothing is lost.
  defp iso(datetime), do: datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  ## Changing schedules

  @doc """
  Creates a schedule in project `project_id` from the owner's form
  (`Photon.Schedules.Rules.schedule/2`: `prompt`, `at`, `repeat`, `every`,
  `unit`, `target`), with its routine task, in one commit. Errors:
  `:not_found` when the project doesn't exist, or a field map.
  """
  @spec create({:project, String.t()}, map()) ::
          {:ok, Schedule.t()} | {:error, :not_found | field_errors()}
  def create({:project, project_id}, params) when is_binary(project_id) do
    now = System.system_time(:millisecond)
    id = PhotonCore.ID.new("sc_")

    Durable.commit(fn tx ->
      with {:ok, project} <- fetch_project(project_id),
           {:ok, attrs} <- Rules.schedule(params, %{now: now, thread_ids: thread_ids(project)}) do
        schedule =
          Repo.insert!(
            struct!(
              %Schedule{id: id, project_id: project.id, version: 1, created_by: "owner"},
              attrs
            )
          )

        schedule = arm_tx(tx, schedule, nil, now)
        :ok = announce(tx, schedule)
        {:ok, schedule}
      end
    end)
  end

  @doc """
  Saves project schedule `id` from its form, given the `version` the form
  loaded. In one commit it re-checks the params, retires the old task,
  bumps the version and arms a new task at the first time the old one
  hadn't fired. When there is none (a one-off that already fired at the
  time it keeps, or a repeating one made a one-off at the time it just
  fired), the schedule is done and no timer is left running. Errors:
  `:not_found` (no such project schedule), `:stale` (it changed since
  the form loaded it), or a field map.
  """
  @spec update(String.t(), map(), pos_integer()) ::
          {:ok, Schedule.t()} | {:error, :not_found | :stale | field_errors()}
  def update(id, params, version) do
    now = System.system_time(:millisecond)

    Durable.commit(fn tx ->
      with {:ok, schedule} <- fetch_project_schedule(id),
           :ok <- not_stale(schedule, version),
           {:ok, project} <- fetch_project(schedule.project_id),
           {:ok, attrs} <- Rules.schedule(params, %{now: now, thread_ids: thread_ids(project)}) do
        save_tx(tx, schedule, attrs, now)
      end
    end)
  end

  # Blip's own schedules change only through Blip's tools.
  defp fetch_project_schedule(id) do
    case fetch_schedule(id) do
      {:ok, %Schedule{project_id: nil}} -> {:error, :not_found}
      result -> result
    end
  end

  defp save_tx(tx, schedule, attrs, now) do
    old = schedule.task_id && Tx.get_task(tx, schedule.task_id)

    schedule =
      schedule
      |> Ecto.Changeset.change(
        attrs
        |> Map.put(:version, schedule.version + 1)
        |> forget_woken(schedule)
      )
      |> Repo.update!()

    schedule = arm_tx(tx, schedule, old, now)
    :ok = announce(tx, schedule)
    {:ok, schedule}
  end

  # A schedule that woke a thread remembers it as its last thread. Made
  # to start a new thread each time, it must not take that thread for one
  # it started, or the overlap rule would skip every firing while the
  # owner works there (`Photon.Schedules.Rules.fire/2`).
  defp forget_woken(%{conversation_id: nil} = attrs, %Schedule{conversation_id: woken} = schedule)
       when is_binary(woken) and schedule.last_thread_id == woken,
       do: Map.put(attrs, :last_thread_id, nil)

  defp forget_woken(attrs, _schedule), do: attrs

  defp not_stale(%Schedule{version: version}, version), do: :ok
  defp not_stale(%Schedule{}, _version), do: {:error, :stale}

  # Every edit replaces the task: the new one waits for the first time the
  # old one hadn't fired. When there is none, the schedule is done: a
  # one-off edited after it fired, keeping its time, or a repeating one
  # made a one-off at the time it just fired. A finished old task stays
  # the row's, so the row still reads as done (or stopped); a live one is
  # retired like any replaced task and the row names none, which reads as
  # done too. A new schedule has no old task. Blip's tool names the
  # task's request ID; otherwise it is the schedule's version
  # (`Photon.Schedules.Routine.task/3`).
  defp arm_tx(tx, schedule, old, now, request_id \\ nil) do
    fired_through = old && Rules.fired_through(old.input, old.checkpoint, old.status)

    case next_ms(schedule, now, fired_through) do
      :finished ->
        finish_tx(tx, schedule, old)

      next_ms ->
        :ok = retire_tx(tx, old)
        task = Tx.create_task(tx, Routine.task(schedule, next_ms, request_id))
        schedule |> Ecto.Changeset.change(task_id: task.id) |> Repo.update!()
    end
  end

  defp finish_tx(tx, schedule, %TaskRecord{} = old) do
    if TaskRecord.terminal?(old) do
      schedule
    else
      :ok = retire_tx(tx, old)
      schedule |> Ecto.Changeset.change(task_id: nil) |> Repo.update!()
    end
  end

  defp finish_tx(_tx, schedule, nil), do: schedule

  defp next_ms(schedule, now, fired_through) do
    Rules.arm(
      DateTime.to_unix(schedule.first_at, :millisecond),
      every_ms(schedule),
      now,
      fired_through
    )
  end

  defp every_ms(%Schedule{every_minutes: nil}), do: nil
  defp every_ms(%Schedule{every_minutes: minutes}), do: minutes * 60_000

  @doc """
  Makes a schedule from Blip's `schedule` tool's arguments (`prompt`,
  `in_minutes` or `at`, `every_minutes`, read by
  `Photon.Schedules.Rules.from_tool/2` with the tool's messages) inside
  the commit that records the tool's result, so the row and its routine
  task exist only if the result does. `target` says where it fires:
  `{:blip, conversation_id}` posts into Blip's conversation, and
  `{:project, project_id, thread_id}` is a project schedule like the
  form's, waking `thread_id` or, with nil, starting a new thread each
  time. A thread that isn't the project's is refused
  (`Photon.Schedules.Rules.tool_thread/3`), as is a project that went
  before the commit.

  `made` says how the call made it (`t:made/0`). The row is
  `created_by: "blip"`, with `asked_by` (`"owner"` or `"blip"`) from the
  run that called the tool (section 5.4 of
  `docs/plans/step-4-blip-as-coordinator.md`); every firing carries both.
  `request_id` is the tool call's (`"schedule:<task id>"`), kept as the
  routine task's request ID: a call that runs again with it gets the
  schedule it already made, not a second one. `now` is the clock the
  tool read (Unix milliseconds), shared by the rules and the arming, so a
  time the rules accept always fires.
  """
  @spec tool_schedule_tx(Tx.t(), tool_target(), map(), made()) ::
          {:ok, Schedule.t()} | {:error, String.t()}
  def tool_schedule_tx(tx, target, args, %{asked_by: asked_by, request_id: request_id, now: now}) do
    case made_for(request_id) do
      %Schedule{} = schedule ->
        {:ok, schedule}

      nil ->
        with {:ok, place} <- tool_place(target),
             {:ok, attrs} <- Rules.from_tool(args, now) do
          schedule =
            Repo.insert!(
              struct!(
                %Schedule{
                  id: PhotonCore.ID.new("sc_"),
                  version: 1,
                  created_by: "blip",
                  asked_by: asked_by
                },
                Map.merge(place, attrs)
              )
            )

          schedule = arm_tx(tx, schedule, nil, now, request_id)
          :ok = announce(tx, schedule)
          {:ok, schedule}
        end
    end
  end

  # The row's place for a tool target: Blip's conversation, or a project
  # and the thread it wakes (nil for a new thread each time).
  defp tool_place({:blip, conversation_id}),
    do: {:ok, %{project_id: nil, conversation_id: conversation_id}}

  defp tool_place({:project, project_id, thread}) do
    case Projects.get(project_id) do
      %Project{} = project ->
        with {:ok, thread_id} <- Rules.tool_thread(thread, thread_ids(project), project.slug),
             do: {:ok, %{project_id: project.id, conversation_id: thread_id}}

      nil ->
        {:error, "That project no longer exists."}
    end
  end

  # The schedule whose routine task carries `request_id`, if one was made.
  defp made_for(request_id) do
    query =
      from(s in Schedule,
        join: t in TaskRecord,
        on: t.id == s.task_id,
        where: t.request_id == ^request_id
      )

    Repo.one(query)
  end

  @doc """
  When a schedule fires, in the words of Blip's tools: "first at
  2026-10-08 09:00 UTC, then every 1440 minutes", or only the first part
  for a one-off.
  """
  @spec when_text(Schedule.t()) :: String.t()
  def when_text(%Schedule{} = schedule),
    do: Rules.when_text(schedule.first_at, schedule.every_minutes)

  @doc """
  Deletes schedule `id` (a project's or Blip's) and retires its task in
  the same commit, so nothing fires afterwards. Threads it started stay.
  """
  @spec delete(String.t()) :: :ok | {:error, :not_found}
  def delete(id) do
    Durable.commit(fn tx ->
      with {:ok, schedule} <- fetch_schedule(id), do: remove_tx(tx, schedule)
    end)
  end

  @doc """
  Deletes schedule `id` inside the caller's commit, as `delete/1` does,
  but only when it is in `scope`: the home page's cancel button passes
  `:blip`, so a project's schedule is `{:error, :not_found}` to it, like
  one that doesn't exist. Blip's `cancel_schedule` tool passes `:any`,
  since Blip manages project schedules too.
  """
  @spec delete_tx(Tx.t(), String.t(), scope() | :any) :: :ok | {:error, :not_found}
  def delete_tx(tx, id, scope) do
    case fetch_schedule(id) do
      {:ok, schedule} ->
        if in_scope?(schedule, scope), do: remove_tx(tx, schedule), else: {:error, :not_found}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp in_scope?(%Schedule{}, :any), do: true
  defp in_scope?(%Schedule{project_id: nil}, :blip), do: true
  defp in_scope?(%Schedule{project_id: project_id}, {:project, project_id}), do: true
  defp in_scope?(%Schedule{}, _scope), do: false

  defp remove_tx(tx, schedule) do
    :ok = retire_tx(tx, schedule.task_id && Tx.get_task(tx, schedule.task_id))
    _deleted = Repo.delete!(schedule)
    announce(tx, schedule)
  end

  # Marks a schedule's task for abort, background work included (a
  # no-op on a finished task); its firing step is then fenced out.
  defp retire_tx(_tx, nil), do: :ok

  defp retire_tx(tx, %TaskRecord{} = task) do
    _retired = Tx.request_abort(tx, task, background: true)
    :ok
  end

  @doc """
  Fires schedule `id` once now, outside its times, and returns what the
  firing did (`"started"`, `"sent"`, `"queued"` or a `"skipped_..."`
  reason). The owner pressed the button, so consent is taken as given;
  the overlap rules still apply. The schedule's task and next time don't
  change.
  """
  @spec run_now(String.t()) :: {:ok, Rules.outcome()} | {:error, :not_found}
  def run_now(id) do
    now = System.system_time(:millisecond)
    request_id = "schedule:#{id}:now:#{PhotonCore.ID.new()}"

    Durable.commit(fn tx ->
      case Routine.fire_tx(tx, id, %{allowed?: true, request_id: request_id, now: now}) do
        {:ok, outcome} -> {:ok, outcome}
        :gone -> {:error, :not_found}
      end
    end)
  end

  ## Helpers

  defp fetch_schedule(id) do
    case Repo.get(Schedule, id) do
      %Schedule{} = schedule -> {:ok, schedule}
      nil -> {:error, :not_found}
    end
  end

  defp fetch_project(project_id) do
    case Projects.get(project_id) do
      %Project{} = project -> {:ok, project}
      nil -> {:error, :not_found}
    end
  end

  defp thread_ids(project), do: Enum.map(Threads.list(project.id), & &1.id)

  @doc false
  # Announces a change to `schedule` inside the commit that made it; for
  # the routine too.
  @spec announce(Tx.t(), Schedule.t()) :: :ok
  def announce(tx, %Schedule{project_id: project_id}),
    do: Tx.announce(tx, @topic, {:schedules_changed, project_id})
end
