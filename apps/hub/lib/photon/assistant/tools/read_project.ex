defmodule Photon.Assistant.Tools.ReadProject do
  @moduledoc """
  Blip's `read_project` tool (`Photon.Assistant.Readout.project/2`). It
  includes each machine's skills (`Photon.Skills.machine_skills/0`), which
  the project's threads get too, so a project with none of its own doesn't
  read as having no skills at all. It changes nothing, so a rerun after a
  restart is safe.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.{Assistant, Projects, Skills, Threads}
  alias Photon.Assistant.Readout
  alias Photon.Durable.ToolSchema

  @impl true
  def name, do: "read_project"

  @impl true
  def description,
    do:
      "Read a project: its purpose, context files, threads with their states, schedules, " <>
        "the skills turned on for it, and those on for a machine, which its threads get " <>
        "for work on that machine."

  @impl true
  def parameters,
    do:
      ToolSchema.object(
        [
          project: Readout.field(:project)
        ],
        [:project]
      )

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
        skills: names(Skills.enabled(scope)),
        machine_skills: for({id, skills} <- Skills.machine_skills(), do: {id, names(skills)})
      }

      {:ok, Readout.project(project, facts),
       %{"project_id" => project.id, "slug" => project.slug}}
    end
  end

  defp names(skills), do: Enum.map(skills, & &1.name)
end
