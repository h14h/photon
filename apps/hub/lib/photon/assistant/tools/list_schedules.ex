defmodule Photon.Assistant.Tools.ListSchedules do
  @moduledoc """
  Blip's `list_schedules` tool: Blip's own schedules that are waiting for
  their next time, and those that stopped after an error, with why
  (`Photon.Assistant.schedules/0`), each with its `sc_` ID for
  `cancel_schedule`. A project's schedules aren't Blip's, so they aren't
  listed.
  """
  @behaviour Photon.Durable.Tool

  @impl true
  def name, do: "list_schedules"

  @impl true
  def description, do: "List your scheduled prompts with their next run times."

  @impl true
  def parameters, do: %{"type" => "object", "properties" => %{}}

  @impl true
  def replay, do: :safe

  @impl true
  def execute(_args, _api) do
    now = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M UTC")

    case Photon.Assistant.schedules() do
      [] ->
        {:ok, "No schedules. (Now: #{now}.)"}

      schedules ->
        {:ok, "Now: #{now}.\n" <> Enum.map_join(schedules, "\n", &schedule_line/1)}
    end
  end

  defp schedule_line(%{schedule: schedule} = item) do
    every = if schedule.every_minutes, do: ", every #{schedule.every_minutes} min", else: ""
    ~s(- #{schedule.id}: #{status(item)}#{every}: "#{schedule.prompt}")
  end

  defp status(%{state: :waiting, next_at: next_at}),
    do: "next " <> Calendar.strftime(next_at, "%Y-%m-%d %H:%M UTC")

  # A stopped schedule won't fire again: cancel it and schedule it anew.
  defp status(%{state: {:stopped, reason}}),
    do:
      "stopped after an error (#{reason}); it won't run again until you cancel it and schedule it anew"
end
