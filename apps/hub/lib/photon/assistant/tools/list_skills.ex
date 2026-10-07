defmodule Photon.Assistant.Tools.ListSkills do
  @moduledoc """
  Blip's `list_skills` tool (section 5.5 of
  `docs/plans/step-4-blip-as-coordinator.md`): every skill on the hub,
  with its description and where it is on, Blip's own set (`you`),
  projects' by slug and machines' as `machine mm1` (`Photon.Skills.list/0`,
  `Photon.Assistant.Readout.skills/1`). `set_project_skill` turns one on
  or off for a project.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.Assistant.Readout
  alias Photon.{Projects, Skills}

  @impl true
  def name, do: "list_skills"

  @impl true
  def description,
    do:
      "List every skill on the hub, with what it's for and where it's on: for you, for " <>
        "a project's threads, or for a machine (the user turns machine skills on and off " <>
        "on the skill's page). A skill on for a machine reaches you and every thread in " <>
        "every project, for work on that machine."

  @impl true
  def parameters, do: %{"type" => "object", "properties" => %{}}

  @impl true
  def replay, do: :safe

  @impl true
  def execute(_args, _api) do
    slugs = Map.new(Projects.list(), &{&1.id, &1.slug})

    skills =
      for %{skill: skill, scopes: scopes} <- Skills.list() do
        %{
          name: skill.name,
          description: skill.description,
          on_for: for(scope <- scopes, place = place(scope, slugs), do: place)
        }
      end

    {:ok, Readout.skills(skills)}
  end

  defp place(:blip, _slugs), do: "you"
  defp place({:project, project_id}, slugs), do: Map.get(slugs, project_id)
  defp place({:machine, machine_id}, _slugs), do: "machine " <> machine_id
end
