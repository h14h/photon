defmodule Photon.Schedules.Routine do
  @moduledoc """
  The `"routine"` task kind: a schedule's timer (section 3.3 of
  `docs/plans/step-3-skills-and-schedules.md`). A background task with no
  conversation of its own sleeps durably until the schedule's next time,
  fires it, and waits again; a one-off finishes after it fires. Slots
  missed while the hub was down are skipped, not fired in a burst
  (`Photon.Schedules.Rules.next_after/3`).

  The task's input is `"schedule_id"`, `"first_at"` (Unix milliseconds,
  what `Photon.Schedules.Rules.arm/4` chose) and `"every_ms"` (nil for a
  one-off); its checkpoint is `"next_at"` and how many times it has fired
  (`"runs"`). `Photon.Schedules` creates it in the commit that creates or
  edits the row, and retires it in the commit that edits or deletes it.

  A firing (`fire_tx/3`, which run-now shares) is one commit: it reads the
  row, gathers the facts `Photon.Schedules.Rules.fire/2` needs (each only
  for an ID that is set), starts a thread, submits the prompt or skips,
  records the outcome on the row and announces it. The message a firing
  sends carries the schedule's ID, who made it (`"created_by"`) and why
  Blip made it (`"asked_by"`, nil for the owner's) as its source. The step reads consent
  and the clock before that commit. `Photon.Durable.Runtime.commit/2`
  keeps all of it or none: a step whose task was marked for abort,
  finished or restarted meanwhile commits nothing, so a firing happens
  once and never after its schedule was edited or deleted.

  `on_fail/3` records a failed task on the row it still carries, so the
  pages say the schedule stopped; it never retries, since a firing that
  crashed would crash the same way again, and saving the schedule arms a
  fresh task.
  """

  @behaviour Photon.Durable.TaskKind

  alias Photon.{Durable, Repo, Schedules, Threads}
  alias Photon.Durable.{Runtime, TaskRecord, Tx}
  alias Photon.Schedules.{Rules, Schedule}

  @typedoc "What a firing goes on: consent, the submission's request ID, and the clock."
  @type firing :: %{allowed?: boolean(), request_id: String.t(), now: Rules.ms()}

  @doc """
  The routine task's attributes for `schedule`, waiting first for
  `next_ms`. Its request ID is `request_id` when given (Blip's tool call,
  so the call makes one schedule), or else names the schedule's version,
  so one edit makes one task.
  """
  @spec task(Schedule.t(), Rules.ms(), String.t() | nil) :: map()
  def task(%Schedule{} = schedule, next_ms, request_id \\ nil) do
    %{
      kind: "routine",
      conversation_id: nil,
      background: true,
      phase: "start",
      request_id: request_id || "schedule:#{schedule.id}:v#{schedule.version}",
      input: %{
        "schedule_id" => schedule.id,
        "first_at" => next_ms,
        "every_ms" => schedule.every_minutes && schedule.every_minutes * 60_000
      }
    }
  end

  @impl true
  def step("start", task, runtime), do: Runtime.transition(runtime, first_wait(task))

  def step("fire", %TaskRecord{input: %{"schedule_id" => id}} = task, runtime)
      when is_binary(id) do
    firing = %{
      allowed?: Schedules.consent?(),
      request_id: request_id(task),
      now: System.system_time(:millisecond)
    }

    Runtime.commit(runtime, fn tx ->
      case fire_tx(tx, id, firing) do
        {:ok, _outcome} -> after_fire(task, firing.now)
        # The row is gone only if the fence failed; finish without writing.
        :gone -> {:done, %{"gone" => true}}
      end
    end)
  end

  @impl true
  def on_fail(%TaskRecord{id: task_id, input: %{"schedule_id" => id}}, _reason, tx) do
    case Repo.get(Schedule, id) do
      %Schedule{task_id: ^task_id} = schedule ->
        schedule = schedule |> Ecto.Changeset.change(last_outcome: "failed") |> Repo.update!()
        Schedules.announce(tx, schedule)

      _replaced_or_gone ->
        :ok
    end
  end

  # Every routine task names its schedule; there is nothing to record otherwise.
  def on_fail(_task, _reason, _tx), do: :ok

  ## A firing

  @doc false
  # Fires schedule `id` inside the caller's commit: steps 1 to 5 of
  # section 3.3, for a firing step and for run-now. Returns what it did,
  # or :gone when there is no such row.
  @spec fire_tx(Tx.t(), String.t(), firing()) :: {:ok, Rules.outcome()} | :gone
  def fire_tx(tx, id, firing) do
    case Repo.get(Schedule, id) do
      nil ->
        :gone

      schedule ->
        target = Rules.target(schedule)
        decision = Rules.fire(target, facts(tx, schedule, target, firing.allowed?))
        {outcome, thread_id} = apply_decision(tx, schedule, target, decision, firing.request_id)

        schedule =
          schedule
          |> Ecto.Changeset.change(
            last_run_at: Rules.datetime(firing.now),
            last_outcome: outcome,
            last_thread_id: thread_id
          )
          |> Repo.update!()

        :ok = Schedules.announce(tx, schedule)
        {:ok, outcome}
    end
  end

  # The facts for Rules.fire/2, read in the firing's commit, each only for
  # an ID that is set: Queries.active_run/1 can't compare with nil.
  defp facts(tx, schedule, :new_thread, allowed?) do
    %{allowed?: allowed?, last_thread_running?: running?(tx, schedule.last_thread_id)}
  end

  defp facts(tx, %Schedule{conversation_id: conversation_id} = schedule, target, allowed?) do
    %{
      allowed?: allowed?,
      thread?: target == :blip or Threads.get(conversation_id) != nil,
      queued?: queued?(tx, conversation_id, schedule.id),
      busy?: running?(tx, conversation_id)
    }
  end

  defp running?(_tx, nil), do: false
  defp running?(tx, conversation_id), do: Tx.active_run(tx, conversation_id) != nil

  defp queued?(tx, conversation_id, schedule_id) do
    tx
    |> Tx.queued(conversation_id)
    |> Enum.any?(&(get_in(&1.content, ["source", "schedule_id"]) == schedule_id))
  end

  # Applies the decision; returns the outcome and the thread to remember
  # as the last one (unchanged by a skip, so a running thread keeps
  # holding off the next new one).
  defp apply_decision(tx, schedule, :new_thread, {:start, outcome}, request_id) do
    {:ok, thread} =
      Threads.start_tx(tx, schedule.project_id, Rules.text(schedule.prompt),
        source: source(schedule),
        request_id: request_id
      )

    {outcome, thread.id}
  end

  defp apply_decision(tx, schedule, :thread, {:submit, outcome}, request_id) do
    {:ok, _submission} =
      Threads.send_tx(tx, schedule.conversation_id, Rules.text(schedule.prompt),
        source: source(schedule),
        request_id: request_id
      )

    {outcome, schedule.conversation_id}
  end

  defp apply_decision(tx, schedule, :blip, {:submit, outcome}, request_id) do
    _submission =
      Durable.submit_tx(tx, schedule.conversation_id, Rules.text(schedule.prompt),
        source: source(schedule),
        request_id: request_id
      )

    {outcome, schedule.last_thread_id}
  end

  defp apply_decision(tx, schedule, target, {:skip, outcome, :notice}, _request_id) do
    _note =
      Tx.append(
        tx,
        schedule.conversation_id,
        "error",
        Rules.skipped_note(target, schedule.prompt)
      )

    {outcome, schedule.last_thread_id}
  end

  defp apply_decision(_tx, schedule, _target, {:skip, outcome, :quiet}, _request_id),
    do: {outcome, schedule.last_thread_id}

  # Every firing names its schedule, who made it and why: threads a
  # schedule Blip made starts or wakes are Blip's work, so Blip hears how
  # they end (`Photon.Signals.Rules.blip_source?/1`), and a firing of one
  # Blip made on its own is its follow-up, while one the owner asked for
  # is a schedule (`Photon.Assistant.Origin`).
  defp source(schedule),
    do: %{
      "kind" => "routine",
      "schedule_id" => schedule.id,
      "created_by" => schedule.created_by,
      "asked_by" => schedule.asked_by
    }

  ## The timer

  @doc false
  # The wait until the next time it fires, counting runs from zero again.
  @spec first_wait(TaskRecord.t()) :: Tx.transition()
  def first_wait(task) do
    next_at = task.checkpoint["next_at"] || task.input["first_at"]
    {:wait, %{"until" => next_at}, "fire", %{"next_at" => next_at, "runs" => 0}}
  end

  @doc false
  # One submission per firing, even if the step runs again.
  @spec request_id(TaskRecord.t()) :: String.t()
  def request_id(task), do: Rules.request_id(task.input["schedule_id"], task.id, runs(task))

  @doc false
  # What follows a firing at `now`: the next wait, or done for a one-off.
  @spec after_fire(TaskRecord.t(), Rules.ms()) :: Tx.transition()
  def after_fire(task, now), do: after_fire(task, task.input["every_ms"], now)

  defp after_fire(task, every, _now) when every in [nil, false],
    do: {:done, %{"runs" => runs(task) + 1}}

  defp after_fire(task, every, now) do
    next_at = Rules.next_after(task.checkpoint["next_at"], every, now)
    {:wait, %{"until" => next_at}, "fire", %{"next_at" => next_at, "runs" => runs(task) + 1}}
  end

  defp runs(task), do: task.checkpoint["runs"] || 0
end
