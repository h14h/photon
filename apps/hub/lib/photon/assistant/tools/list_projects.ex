defmodule Photon.Assistant.Tools.ListProjects do
  @moduledoc """
  Blip's `list_projects` tool: every project, by name, with the first
  sentence of its purpose, how many of its threads are in each state and how
  many context files it has (`Photon.Assistant.Readout.projects/3`). It
  changes nothing, so a rerun after a restart is safe.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.Assistant.Readout
  alias Photon.{Projects, Threads}

  @impl true
  def name, do: "list_projects"

  @impl true
  def description,
    do:
      "List every project: its slug, name and purpose, how many of its threads are running, " <>
        "waiting on the user, failed and so on, and how many context files it has."

  @impl true
  def parameters, do: %{"type" => "object", "properties" => %{}}

  @impl true
  def replay, do: :safe

  @impl true
  def execute(_args, _api),
    do: {:ok, Readout.projects(Projects.list(), Threads.board(:all), Projects.file_counts())}
end
