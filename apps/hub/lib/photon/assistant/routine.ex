defmodule Photon.Assistant.Routine do
  @moduledoc """
  A scheduled prompt: a background task that sleeps durably until its next
  time, then posts `"[Scheduled] <prompt>"` into the assistant's conversation.
  Recurring routines repeat every `every_ms`, skipping runs missed while
  the hub was down; one-off routines finish after they fire.

  The task's input holds `"prompt"`, `"first_at"` (Unix milliseconds) and
  `"every_ms"` (nil for a one-off); its checkpoint, `"next_at"` and how many
  times it has fired (`"runs"`).
  """

  @behaviour Photon.Durable.TaskKind

  alias Photon.Durable
  alias Photon.Durable.{Runtime, TaskRecord}

  @impl true
  def step("start", task, runtime), do: Runtime.transition(runtime, first_wait(task))

  def step("fire", task, runtime) do
    Runtime.commit(runtime, fn tx ->
      _prompt =
        Durable.submit_tx(tx, task.conversation_id, prompt(task),
          request_id: request_id(task),
          source: %{"kind" => "routine", "schedule_id" => task.id}
        )

      after_fire(task, System.system_time(:millisecond))
    end)
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
