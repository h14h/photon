defmodule Photon.Assistant.Routine do
  @moduledoc """
  A scheduled prompt: a background task that sleeps durably until its next
  time, then posts `"[Scheduled] <prompt>"` into the assistant's conversation.
  Recurring routines repeat every `every_ms`, skipping runs missed while
  the hub was down; one-off routines finish after they fire.

  The task's input holds `"prompt"`, `"first_at"` (Unix milliseconds) and
  `"every_ms"` (nil for a one-off); its checkpoint, `"next_at"` and how many
  times it has fired (`"runs"`).

  A scheduled run uses the user's ChatGPT plan while they're away, which
  needs their consent (`Photon.Settings.scheduled_work?/1`). Without it the
  routine posts a quiet note that it skipped the run, and keeps its
  schedule.
  """

  @behaviour Photon.Durable.TaskKind

  alias Photon.{Durable, Settings}
  alias Photon.Durable.{Runtime, TaskRecord, Tx}

  @impl true
  def step("start", task, runtime), do: Runtime.transition(runtime, first_wait(task))

  def step("fire", task, runtime) do
    allowed? = scheduled_work?()

    Runtime.commit(runtime, fn tx ->
      :ok = fire(tx, task, allowed?)
      after_fire(task, System.system_time(:millisecond))
    end)
  end

  defp fire(tx, task, true = _allowed) do
    _prompt =
      Durable.submit_tx(tx, task.conversation_id, prompt(task),
        request_id: request_id(task),
        source: %{"kind" => "routine", "schedule_id" => task.id}
      )

    :ok
  end

  defp fire(tx, task, false = _allowed) do
    _note = Tx.append(tx, task.conversation_id, "error", skipped(task))
    :ok
  end

  # The scripted model (tests, development) uses nobody's plan.
  defp scheduled_work? do
    Application.get_env(:photon, :mock_model, false) or Settings.scheduled_work?(Settings.load())
  end

  @doc false
  # The note a run skipped for want of consent leaves.
  @spec skipped(TaskRecord.t()) :: map()
  def skipped(task) do
    %{
      "message" =>
        ~s{Skipped "#{task.input["prompt"]}": scheduled work is off. Turn it on in Settings to let me use your plan while you're away.},
      "notice" => true
    }
  end

  @doc false
  # The wait until the next time it fires, counting runs from zero again.
  @spec first_wait(TaskRecord.t()) :: Durable.Tx.transition()
  def first_wait(task) do
    next_at = task.checkpoint["next_at"] || task.input["first_at"]
    {:wait, %{"until" => next_at}, "fire", %{"next_at" => next_at, "runs" => 0}}
  end

  @doc false
  @spec prompt(TaskRecord.t()) :: String.t()
  def prompt(task), do: "[Scheduled] " <> task.input["prompt"]

  @doc false
  # One submission per firing, even if the step runs again.
  @spec request_id(TaskRecord.t()) :: String.t()
  def request_id(task), do: "routine:#{task.id}:#{runs(task)}"

  @doc false
  # What follows a firing at `now`: the next wait, or done for a one-off.
  @spec after_fire(TaskRecord.t(), integer()) :: Durable.Tx.transition()
  def after_fire(task, now), do: after_fire(task, task.input["every_ms"], now)

  defp after_fire(task, every, _now) when every in [nil, false],
    do: {:done, %{"runs" => runs(task) + 1}}

  defp after_fire(task, every, now) do
    next_at = next_after(task.checkpoint["next_at"], every, now)
    {:wait, %{"until" => next_at}, "fire", %{"next_at" => next_at, "runs" => runs(task) + 1}}
  end

  defp runs(task), do: task.checkpoint["runs"] || 0

  @doc false
  # The first time after `now` on the routine's grid, so runs missed while
  # the hub was down are skipped rather than fired in a burst.
  @spec next_after(integer(), pos_integer(), integer()) :: integer()
  def next_after(at, every, now) do
    missed = div(max(now - at, 0), every)
    at + (missed + 1) * every
  end
end
