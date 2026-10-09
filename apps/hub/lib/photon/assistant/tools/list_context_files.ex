defmodule Photon.Assistant.Tools.ListContextFiles do
  @moduledoc """
  Blip's `list_context_files` tool: one project's context files as a
  thread's tool of the same name lists them, seen from Blip's side
  (`Photon.Threads.describe_files/2` with the viewer `"blip"`). It changes
  nothing, so a rerun after a restart is safe.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.{Assistant, Threads}
  alias Photon.Assistant.Readout
  alias Photon.Durable.ToolSchema

  @impl true
  def name, do: "list_context_files"

  @impl true
  def description,
    do:
      "List a project's context files (Markdown notes the user and the project's threads " <>
        "share), newest change first, with their size and who changed them last."

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
      {:ok, Threads.describe_files(project.id, "blip"),
       %{"project_id" => project.id, "slug" => project.slug}}
    end
  end
end
