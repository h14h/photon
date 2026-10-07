defmodule Photon.Assistant.Tools.ListThreads do
  @moduledoc """
  Blip's `list_threads` tool (section 5.2 of
  `docs/plans/step-4-blip-as-coordinator.md`): the threads of every
  project, or of one, optionally only those in one state, most recent
  activity first, each with its state and its open questions or last
  run's note (`Photon.Assistant.Readout.threads/2`). It changes nothing,
  so a rerun after a restart is safe.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.{Assistant, Threads}
  alias Photon.Assistant.Readout

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
    do: %{
      "type" => "object",
      "properties" => %{
        "project" => %{
          "type" => "string",
          "description" =>
            "Only this project's threads: its slug, like garden (list_projects shows them), " <>
              "or its ID."
        },
        "state" => %{
          "type" => "string",
          "enum" => Readout.state_names(),
          "description" =>
            "Only threads in this state: running, asking (asking you a question), waiting " <>
              "(on the user), failed, unread (finished, not yet seen by the user), quiet " <>
              "(stopped and left alone for days) or idle."
        }
      }
    }

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
