defmodule Photon.Threads.Tools.ListContextFiles do
  @moduledoc """
  The `list_context_files` tool: the thread's project's context files,
  newest change first, each with its size, when it changed and who changed
  it, through `Photon.Threads.describe_files/2`, which Blip's tool of the
  same name shares. It changes nothing, so a rerun after a restart is safe.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.Durable.ToolSchema
  alias Photon.Threads

  @impl true
  def name, do: "list_context_files"

  @impl true
  def description,
    do:
      "List the project's context files (Markdown notes shared with the user and the " <>
        "project's other threads), newest change first, with their size and who changed them last."

  @impl true
  def parameters, do: ToolSchema.object([])

  @impl true
  def replay, do: :safe

  @impl true
  def execute(_args, api) do
    thread_id = api.conversation_id
    {:ok, thread_id |> Threads.project_id!() |> Threads.describe_files(thread_id)}
  end
end
