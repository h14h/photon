defmodule Photon.Threads.Tools.ReadContextFile do
  @moduledoc """
  The `read_context_file` tool: one of the project's context files, after a
  line naming it with its size, when it changed and who changed it, through
  `Photon.Threads.read_file_text/3`, which Blip's tool of the same name
  shares. A missing file is an error result that lists the files there are.
  It changes nothing, so a rerun after a restart is safe.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.Threads

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
    thread_id |> Threads.project_id!() |> Threads.read_file_text(name, thread_id)
  end
end
