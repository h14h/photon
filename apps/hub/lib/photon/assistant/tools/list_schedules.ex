defmodule Photon.Assistant.Tools.ListSchedules do
  @moduledoc """
  Blip's `list_schedules` tool. Without `project`: Blip's own schedules
  that are waiting for their next time, and those that stopped after an
  error, with why (`Photon.Assistant.schedules/0`). With `project`: that
  project's, the same way, each with what it does when it fires (starts a
  new thread, or wakes one), as `read_project` lists them
  (`Photon.Assistant.project_schedules/1`, `Photon.Assistant.Readout.schedules/4`).
  Each has its `sc_` ID for `cancel_schedule`.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.{Assistant, Threads}
  alias Photon.Assistant.Readout
  alias Photon.Durable.ToolSchema

  @impl true
  def name, do: "list_schedules"

  @impl true
  def description,
    do:
      "List scheduled prompts with their next run times: your own, or with project, that project's."

  @impl true
  def parameters,
    do:
      ToolSchema.object(
        project:
          {:string,
           "To list a project's schedules, its slug (list_projects shows them). Leave it out for your own."}
      )

  @impl true
  def replay, do: :safe

  @impl true
  def execute(%{"project" => name}, _api) when is_binary(name) and name != "" do
    with {:ok, project} <- Assistant.find_project(name) do
      titles = Map.new(Threads.list(project.id), &{&1.id, &1.title})
      schedules = Assistant.project_schedules(project.id)

      {:ok, Readout.schedules(project.slug, schedules, titles, DateTime.utc_now()),
       %{"project_id" => project.id, "slug" => project.slug}}
    end
  end

  def execute(_args, _api) do
    now = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M UTC")

    case Assistant.schedules() do
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
