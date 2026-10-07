defmodule Photon.Assistant.Tools.ReadProject do
  @moduledoc """
  Blip's `read_project` tool (section 5.2 of
  `docs/plans/step-4-blip-as-coordinator.md`): one project's name, slug
  and whole purpose, its context files, its threads with their states,
  its schedules but one-offs that fired (`Photon.Assistant.project_schedules/1`)
  and the skills turned on for it (`Photon.Assistant.Readout.project/2`). The details name the project,
  for the line in Blip's panel. It changes nothing, so a rerun after a
  restart is safe.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.{Assistant, Projects, Skills, Threads}
  alias Photon.Assistant.Readout

  @impl true
  def name, do: "read_project"

  @impl true
  def description,
    do:
      "Read a project: its purpose, context files, threads with their states, schedules and " <>
        "the skills turned on for it."

  @impl true
  def parameters,
    do: %{
      "type" => "object",
      "properties" => %{
        "project" => %{
          "type" => "string",
          "description" =>
            "The project's slug, like garden (list_projects shows them), or its ID."
        }
      },
      "required" => ["project"]
    }

  @impl true
  def replay, do: :safe

  @impl true
  def execute(%{"project" => name}, _api) do
    with {:ok, project} <- Assistant.find_project(name) do
      scope = {:project, project.id}

      facts = %{
        files: Projects.list_files(project.id),
        board: Threads.board(scope),
        schedules: Assistant.project_schedules(project.id),
        skills: Enum.map(Skills.enabled(scope), & &1.name)
      }

      {:ok, Readout.project(project, facts),
       %{"project_id" => project.id, "slug" => project.slug}}
    end
  end
end
