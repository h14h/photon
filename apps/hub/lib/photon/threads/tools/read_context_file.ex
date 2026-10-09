defmodule Photon.Threads.Tools.ReadContextFile do
  @moduledoc """
  The `read_context_file` tool, through `Photon.Threads.read_file_text/3`
  as Blip's is. It changes nothing, so a rerun after a restart is safe.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.Durable.ToolSchema
  alias Photon.Projects.Rules
  alias Photon.Threads

  @impl true
  def name, do: "read_context_file"

  @impl true
  def description,
    do: "Read one of the project's context files, like notes.md."

  @impl true
  def parameters,
    do:
      ToolSchema.object(
        [
          name: Rules.file_field(:name)
        ],
        [:name]
      )

  @impl true
  def replay, do: :safe

  @impl true
  def execute(%{"name" => name}, api) do
    thread_id = api.conversation_id
    thread_id |> Threads.project_id!() |> Threads.read_file_text(name, thread_id)
  end
end
