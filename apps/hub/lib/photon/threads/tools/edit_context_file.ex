defmodule Photon.Threads.Tools.EditContextFile do
  @moduledoc """
  The `edit_context_file` tool: replaces one passage of one of the
  project's context files, which must occur in it exactly once (section
  3.3 of `docs/plans/step-2-projects-and-threads.md`).

  Like `write_context_file`, the edit happens inside the commit that
  records the call's result (`{:commit, fun}`), through
  `Photon.Projects.edit_file_tx/6`, which reads the current content,
  checks everything and announces the change. A refused edit changes
  nothing.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.{Projects, Threads}
  alias Photon.Threads.Rules

  @impl true
  def name, do: "edit_context_file"

  @impl true
  def description,
    do:
      "Change one passage of one of the project's context files: old_text, which must " <>
        "appear in the file exactly once, becomes new_text. Give enough of the passage to " <>
        "pick out one place."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
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
      "required" => ["name", "old_text", "new_text"]
    }
  end

  @impl true
  def replay, do: :safe

  @impl true
  def execute(%{"name" => name, "old_text" => old_text, "new_text" => new_text}, api) do
    thread_id = api.conversation_id
    project_id = Threads.project_id!(thread_id)

    {:commit,
     fn tx ->
       case Projects.edit_file_tx(tx, project_id, name, old_text, new_text, thread_id) do
         {:ok, file} ->
           {:ok, "Edited #{file.name} (#{Rules.characters(file.content)} now).",
            %{"file" => file.name, "version" => file.version}}

         {:error, message} ->
           {:error, message}
       end
     end}
  end
end
