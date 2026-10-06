defmodule Photon.Assistant.Tools.ListSchedules do
  @moduledoc """
  Blip's `list_schedules` tool: Blip's own schedules that are waiting for
  their next time (`Photon.Assistant.schedules/0`), with their `sc_` IDs
  for `cancel_schedule`. A project's schedules aren't Blip's, so they
  aren't listed.
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

  defp schedule_line(%{schedule: schedule, next_at: next_at}) do
    next = Calendar.strftime(next_at, "%Y-%m-%d %H:%M UTC")
    every = if schedule.every_minutes, do: ", every #{schedule.every_minutes} min", else: ""
    ~s(- #{schedule.id}: next #{next}#{every}: "#{schedule.prompt}")
  end
end
