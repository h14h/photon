defmodule Photon.Threads.Tools.WriteContextFile do
  @moduledoc """
  The `write_context_file` tool: creates one of the project's context files
  or replaces all of it. There is no version check: the last write wins
  (`docs/decisions.md#context-files`).

  The write happens inside the commit that records the call's result
  (`{:commit, fun}`), through `Photon.Projects.write_file_tx/5`, which
  checks the name and content and announces the change. So the tool checks
  nothing itself, a refused write changes nothing, a call stopped before
  its commit keeps none of it, and a rerun after a restart either finds
  nothing done or never runs.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.Durable.ToolSchema
  alias Photon.{Projects, Threads}
  alias Photon.Threads.Rules

  @impl true
  def name, do: "write_context_file"

  @impl true
  def description,
    do:
      "Create one of the project's context files, or replace all of it. Read a file before " <>
        "rewriting it, since the user and other threads may have changed it; to change one " <>
        "passage, use edit_context_file instead."

  @impl true
  def parameters,
    do:
      ToolSchema.object(
        [
          name: Projects.Rules.file_field(:new_name),
          content: Projects.Rules.file_field(:content)
        ],
        [:name, :content]
      )

  @impl true
  def replay, do: :safe

  @impl true
  def execute(%{"name" => name, "content" => content}, api) do
    thread_id = api.conversation_id
    project_id = Threads.project_id!(thread_id)

    {:commit,
     fn tx ->
       case Projects.write_file_tx(tx, project_id, name, content, thread_id) do
         {:ok, %{file: file, created?: created?}} ->
           verb = if created?, do: "Created", else: "Wrote"

           {:ok, "#{verb} #{file.name} (#{Rules.characters(file.content)}).",
            %{"file" => file.name, "version" => file.version}}

         {:error, message} ->
           {:error, message}
       end
     end}
  end
end
