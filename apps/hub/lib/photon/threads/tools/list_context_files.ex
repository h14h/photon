defmodule Photon.Threads.Tools.ListContextFiles do
  @moduledoc """
  The `list_context_files` tool: the thread's project's context files,
  newest change first, each with its size, when it changed and who changed
  it (section 3.3 of `docs/plans/step-2-projects-and-threads.md`). It
  changes nothing, so a rerun after a restart is safe.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.{Projects, Threads}
  alias Photon.Threads.Rules

  @impl true
  def name, do: "list_context_files"

  @impl true
  def description,
    do:
      "List the project's context files (Markdown notes shared with the user and the " <>
        "project's other threads), newest change first, with their size and who changed them last."

  @impl true
  def parameters, do: %{"type" => "object", "properties" => %{}}

  @impl true
  def replay, do: :safe

  @impl true
  def execute(_args, api) do
    thread_id = api.conversation_id
    files = thread_id |> Threads.project_id!() |> Projects.list_files()
    titles = files |> Enum.map(& &1.updated_by) |> Enum.uniq() |> Threads.titles()
    {:ok, Rules.listing(files, thread_id, titles)}
  end
end
