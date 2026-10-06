defmodule Photon.Threads.Tools.ReadContextFile do
  @moduledoc """
  The `read_context_file` tool: one of the project's context files, after
  a line naming it with its size, when it changed and who changed it
  (section 3.3 of `docs/plans/step-2-projects-and-threads.md`). A missing
  file is an error result that lists the files there are. It changes
  nothing, so a rerun after a restart is safe.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.{Projects, Threads}
  alias Photon.Threads.Rules

  @impl true
  def name, do: "read_context_file"

  @impl true
  def description,
    do: "Read one of the project's context files, like notes.md."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "description" => "The file's name, like notes.md."}
      },
      "required" => ["name"]
    }
  end

  @impl true
  def replay, do: :safe

  @impl true
  def execute(%{"name" => name}, api) do
    thread_id = api.conversation_id
    project_id = Threads.project_id!(thread_id)

    case Projects.get_file(project_id, name) do
      nil ->
        names = project_id |> Projects.list_files() |> Enum.map(& &1.name)
        {:error, Rules.missing_file(String.trim(name), names)}

      file ->
        titles = Threads.titles([file.updated_by])
        {:ok, Rules.file_header(file, thread_id, titles) <> "\n" <> file.content}
    end
  end
end
