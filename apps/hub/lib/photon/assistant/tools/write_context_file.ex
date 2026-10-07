defmodule Photon.Assistant.Tools.WriteContextFile do
  @moduledoc """
  Blip's `write_context_file` tool (section 5.2 of
  `docs/plans/step-4-blip-as-coordinator.md`): creates one of a project's
  context files or replaces all of it, as written by Blip
  (`updated_by: "blip"`). There is no version check: the last write wins.

  The write happens inside the commit that records the call's result
  (`{:commit, fun}`), through `Photon.Projects.write_file_tx/5`, which
  checks the name and content and announces the change. So a refused
  write changes nothing, a call stopped before its commit keeps none of
  it, and a rerun after a restart either finds nothing done or never
  runs. The project is looked up first (`Photon.Assistant.find_project/1`);
  one that goes before the commit gets `That project no longer exists.`

  A run that carries a thread's question, and that the owner hasn't
  written into, can't change a project (`Photon.Assistant.may_act_tx/3`).
  """
  @behaviour Photon.Durable.Tool

  alias Photon.{Assistant, Projects}
  alias Photon.Assistant.Readout

  @impl true
  def name, do: "write_context_file"

  @impl true
  def description,
    do:
      "Create one of a project's context files, or replace all of it. Read a file before " <>
        "rewriting it, since the user and the project's threads may have changed it; to change " <>
        "one passage, use edit_context_file instead."

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
        "name" => %{
          "type" => "string",
          "description" =>
            ~s(The file's name: letters, digits, ".", "_" and "-", like notes.md. ) <>
              "Files are flat, with no folders."
        },
        "content" => %{
          "type" => "string",
          "description" => "The whole file, in Markdown; at most 100,000 characters."
        }
      },
      "required" => ["project", "name", "content"]
    }

  @impl true
  def replay, do: :safe

  @impl true
  def execute(%{"project" => project_name, "name" => name, "content" => content}, api) do
    with {:ok, project} <- Assistant.find_project(project_name),
         do: {:commit, &write(&1, api, project, name, content)}
  end

  defp write(tx, api, project, name, content) do
    with :ok <- Assistant.may_act_tx(tx, api.task, :change),
         {:ok, %{file: file, created?: created?}} <-
           Projects.write_file_tx(tx, project.id, name, content, "blip") do
      {:ok, Readout.file_written(file.name, project.slug, file.content, created?),
       %{
         "project_id" => project.id,
         "slug" => project.slug,
         "file" => file.name,
         "version" => file.version
       }}
    end
  end
end
