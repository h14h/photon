defmodule Photon.Assistant.Tools.ListContextFiles do
  @moduledoc """
  Blip's `list_context_files` tool (section 5.2 of
  `docs/plans/step-4-blip-as-coordinator.md`): one project's context
  files, newest change first, each with its size, when it changed and who
  changed it, as a thread's tool of the same name lists them but seen from
  Blip's side (`Photon.Threads.describe_files/2` with the viewer
  `"blip"`). The details name the project, for the line in Blip's panel.
  It changes nothing, so a rerun after a restart is safe.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.{Assistant, Threads}

  @impl true
  def name, do: "list_context_files"

  @impl true
  def description,
    do:
      "List a project's context files (Markdown notes the user and the project's threads " <>
        "share), newest change first, with their size and who changed them last."

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
      {:ok, Threads.describe_files(project.id, "blip"),
       %{"project_id" => project.id, "slug" => project.slug}}
    end
  end
end
