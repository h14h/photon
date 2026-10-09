defmodule Photon.Assistant.Tools.ReadContextFile do
  @moduledoc """
  Blip's `read_context_file` tool: one of a project's context files after a
  line naming it with its size, when it changed and who changed it, as a
  thread's tool of the same name reads it but seen from Blip's side
  (`Photon.Threads.read_file_text/3` with the viewer `"blip"`). A missing
  file is an error that lists the files there are. The details name the
  project and the file, for the line in Blip's panel. It changes nothing, so
  a rerun after a restart is safe.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.{Assistant, Threads}

  @impl true
  def name, do: "read_context_file"

  @impl true
  def description,
    do: "Read one of a project's context files, like notes.md in garden."

  @impl true
  def parameters,
    do: %{
      "type" => "object",
      "properties" => %{
        "project" => %{
          "type" => "string",
          "description" =>
            "The project's slug, like garden (list_projects shows them), or its ID."
        },
        "name" => %{"type" => "string", "description" => "The file's name, like notes.md."}
      },
      "required" => ["project", "name"]
    }

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
