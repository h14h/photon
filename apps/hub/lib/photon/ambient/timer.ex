defmodule Photon.Ambient.Timer do
  @moduledoc """
  The `"ambient"` task kind: ambient mode's two timers, the digest and the
  daily review (section 6 of `docs/plans/step-5-ambient-mode.md`). It is
  a schedule's routine (`Photon.Schedules.Routine`) reused for both jobs:
  a background task with no conversation sleeps durably until its time,
  fires, and waits again.

  The task's input is `"job"` (`"digest"` or `"review"`), `"first_at"`
  (Unix milliseconds) and `"every_ms"` (the digest's interval, or a day);
  its checkpoint is `"next_at"` and how many times it has fired
  (`"runs"`). `Photon.Ambient.configure/1` creates it (`task/2`) in the
  commit that turns ambient mode on or changes it, and retires it in the
  commit that turns it off or replaces it.

  A firing reads consent and the clock, then runs `Photon.Ambient.fire_tx/3`
  and its next wait in one `Photon.Durable.Runtime.commit/2`: a step whose
  task was retired, or that is left over from before a Scheduler restart,
  commits nothing. The signal's key is the task and its run count, so a
  step that runs again can't post a second message. The next time is on
  the timer's grid (`Photon.Ambient.Rules.next_firing/3`): a hub that was
  down past its time fires once when it comes back, then keeps to it.

  `on_fail/3` records the failure on the doc while the task is still the
  doc's, so the pages say ambient mode stopped and why. It never retries,
  since a firing that crashed would crash the same way, and saving
  Settings arms a new timer. A retired timer leaves nothing to undo, so
  there is no `on_abort/2`.
  """

  @behaviour Photon.Durable.TaskKind

  alias Photon.{Ambient, Schedules}
  alias Photon.Ambient.Rules
  alias Photon.Durable.{Runtime, TaskRecord}

  @typedoc """
  A timer's first time, its interval (Unix milliseconds) and the doc's
  version that armed it.
  """
  @type arming :: %{first_at: integer(), every_ms: pos_integer(), version: non_neg_integer()}

  @doc """
  The task attributes of `job`'s timer (`"digest"` or `"review"`), as
  armed by `arming`. Its request ID names the job and the doc's version,
  so one arming makes one task.
  """
  @spec task(String.t(), arming()) :: map()
  def task(job, %{first_at: first_at, every_ms: every_ms, version: version}) do
    %{
      kind: "ambient",
      conversation_id: nil,
      background: true,
      phase: "start",
      request_id: "ambient:#{job}:v#{version}",
      input: %{"job" => job, "first_at" => first_at, "every_ms" => every_ms}
    }
  end

  @impl true
  def step("start", task, runtime) do
    next_at = task.checkpoint["next_at"] || task.input["first_at"]
    wait = {:wait, %{"until" => next_at}, "fire", %{"next_at" => next_at, "runs" => 0}}
    Runtime.transition(runtime, wait)
  end

  def step("fire", %TaskRecord{input: %{"job" => job, "every_ms" => every_ms}} = task, runtime) do
    runs = task.checkpoint["runs"] || 0

    firing = %{
      allowed?: Schedules.consent?(),
      key: "#{job}:#{task.id}:#{runs}",
      now: System.system_time(:millisecond)
    }

    Runtime.commit(runtime, fn tx ->
      # What the firing did is on the doc, which it wrote in this commit.
      _result = Ambient.fire_tx(tx, job, firing)
      next_at = Rules.next_firing(task.checkpoint["next_at"], every_ms, firing.now)
      {:wait, %{"until" => next_at}, "fire", %{"next_at" => next_at, "runs" => runs + 1}}
    end)
  end

  @impl true
  def on_fail(%TaskRecord{id: task_id, input: input}, reason, tx) do
    job = if is_map(input), do: input["job"]
    Ambient.stopped_tx(tx, task_id, job, reason)
  end
end
