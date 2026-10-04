defmodule Photon.Assistant.Tools.ListSchedules do
  @moduledoc false
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

  defp schedule_line(task) do
    next =
      (task.checkpoint["next_at"] || task.input["first_at"])
      |> DateTime.from_unix!(:millisecond)
      |> Calendar.strftime("%Y-%m-%d %H:%M UTC")

    every =
      if task.input["every_ms"],
        do: ", every #{div(task.input["every_ms"], 60_000)} min",
        else: ""

    ~s(- #{task.id}: next #{next}#{every}: "#{task.input["prompt"]}")
  end
end
