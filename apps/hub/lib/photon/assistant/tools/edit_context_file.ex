defmodule Photon.Assistant.Tools.EditContextFile do
  @moduledoc """
  Blip's `edit_context_file` tool: replaces one passage of one of a
  project's context files, which must occur in it exactly once, as written
  by Blip (`updated_by: "blip"`).

  Like `write_context_file`, the edit happens inside the commit that
  records the call's result (`{:commit, fun}`), through
  `Photon.Projects.edit_file_tx/6`, which reads the current content,
  checks everything and announces the change. A refused edit changes
  nothing.

  A run that carries a thread's question, and that the owner hasn't
  written into, can't change a project (`Photon.Assistant.may_act_tx/3`).
  """
  @behaviour Photon.Durable.Tool

  alias Photon.{Assistant, Projects}
  alias Photon.Assistant.Readout

  @impl true
  def name, do: "edit_context_file"

  @impl true
  def description,
    do:
      "Change one passage of one of a project's context files: old_text, which must appear " <>
        "in the file exactly once, becomes new_text. Give enough of the passage to pick out " <>
        "one place."

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
        "name" => %{"type" => "string", "description" => "The file's name, like notes.md."},
        "old_text" => %{
          "type" => "string",
          "description" => "The passage to replace, exactly as it is in the file."
        },
        "new_text" => %{
          "type" => "string",
          "description" => "What replaces it; empty to delete the passage."
        }
      },
      "required" => ["project", "name", "old_text", "new_text"]
    }

  @impl true
  def replay, do: :safe

  @impl true
  def execute(%{"project" => project_name, "name" => name} = args, api) do
    %{"old_text" => old_text, "new_text" => new_text} = args

    with {:ok, project} <- Assistant.find_project(project_name),
         do: {:commit, &edit(&1, api, project, name, {old_text, new_text})}
  end

  defp edit(tx, api, project, name, {old_text, new_text}) do
    with {:ok, _origin} <- Assistant.may_act_tx(tx, api.task, :change),
         {:ok, file} <- Projects.edit_file_tx(tx, project.id, name, old_text, new_text, "blip") do
      {:ok, Readout.file_edited(file.name, project.slug),
       %{
         "project_id" => project.id,
         "slug" => project.slug,
         "file" => file.name,
         "version" => file.version
       }}
    end
  end
end
