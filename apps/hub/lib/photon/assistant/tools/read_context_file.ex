defmodule Photon.Assistant.Tools.ReadContextFile do
  @moduledoc """
  Blip's `read_context_file` tool: one of a project's context files as a
  thread's tool of the same name reads it, seen from Blip's side
  (`Photon.Threads.read_file_text/3` with the viewer `"blip"`). It changes
  nothing, so a rerun after a restart is safe.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.{Assistant, Threads}
  alias Photon.Assistant.Readout
  alias Photon.Durable.ToolSchema
  alias Photon.Projects.Rules

  @impl true
  def name, do: "read_context_file"

  @impl true
  def description,
    do: "Read one of a project's context files, like notes.md in garden."

  @impl true
  def parameters,
    do:
      ToolSchema.object(
        [
          project: Readout.field(:project),
          name: Rules.file_field(:name)
        ],
        [:project, :name]
      )

  @impl true
  def replay, do: :safe

  @impl true
  def execute(%{"project" => project_name, "name" => name}, _api) do
    with {:ok, project} <- Assistant.find_project(project_name),
         {:ok, text} <- Threads.read_file_text(project.id, name, "blip") do
      {:ok, text, %{"project_id" => project.id, "slug" => project.slug}}
    end
  end
end
