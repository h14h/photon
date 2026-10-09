defmodule Photon.Assistant.Tools.ListThreads do
  @moduledoc """
  Blip's `list_threads` tool (`Photon.Assistant.Readout.threads/2`). It
  changes nothing, so a rerun after a restart is safe.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.{Assistant, Threads}
  alias Photon.Assistant.Readout
  alias Photon.Durable.ToolSchema

  @impl true
  def name, do: "list_threads"

  @impl true
  def description,
    do:
      "List threads, most recent activity first, with each one's ID, title, project and state, " <>
        "and its open questions or how its last run ended. Name a project, a state, or both " <>
        "to see fewer."

  @impl true
  def parameters,
    do:
      ToolSchema.object(
        project:
          {:string,
           "Only this project's threads: its slug, like garden (list_projects shows them), " <>
             "or its ID."},
        state:
          {:string,
           "Only threads in this state: running, asking (asking you a question), waiting " <>
             "(on the user), failed, unread (finished, not yet seen by the user), quiet " <>
             "(stopped and left alone for days) or idle.", enum: Readout.state_names()}
      )

  @impl true
  def replay, do: :safe

  @impl true
  def execute(args, _api) do
    state = Readout.state_named(args["state"])

    case args["project"] do
      nil ->
        {:ok, Readout.threads(Threads.board(:all), %{project: nil, state: state})}

      name ->
        with {:ok, project} <- Assistant.find_project(name) do
          board = Threads.board({:project, project.id})

          {:ok, Readout.threads(board, %{project: project.slug, state: state}),
           %{"project_id" => project.id, "slug" => project.slug}}
        end
    end
  end
end
