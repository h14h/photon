defmodule Photon.Assistant.Tools.SetProjectSkill do
  @moduledoc """
  Blip's `set_project_skill` tool (section 5.5 of
  `docs/plans/step-4-blip-as-coordinator.md`): turns a skill on or off
  for a project's threads, inside the commit that records the call's
  result (`Photon.Skills.enable_tx/3`, `disable_tx/3`), so a rerun after
  a restart changes nothing twice. The skill is found by name in that
  commit; a project holds at most 30. Blip's own set stays the owner's to
  change, on the Skills page.

  A run that carries a thread's question, and that the owner hasn't
  written into, can't change a project (`Photon.Assistant.may_act_tx/3`).
  """
  @behaviour Photon.Durable.Tool

  alias Photon.{Assistant, Skills}
  alias Photon.Assistant.Readout
  alias Photon.Skills.Skill

  @impl true
  def name, do: "set_project_skill"

  @impl true
  def description,
    do:
      "Turn a skill on or off for a project's threads. Their prompts list the skills on " <>
        "for their project, and they load one when a task calls for it. list_skills shows them."

  @impl true
  def parameters,
    do: %{
      "type" => "object",
      "properties" => %{
        "project" => %{
          "type" => "string",
          "description" =>
            "The project's slug, like garden (list_projects shows them), or its ID."
        },
        "skill" => %{"type" => "string", "description" => "The skill's name, like pdf-forms."},
        "on" => %{
          "type" => "boolean",
          "description" => "true to turn it on, false to turn it off."
        }
      },
      "required" => ["project", "skill", "on"]
    }

  @impl true
  def replay, do: :safe

  @impl true
  def execute(%{"project" => name, "skill" => skill, "on" => on}, api) when is_boolean(on) do
    with {:ok, project} <- Assistant.find_project(name) do
      skill = skill |> String.trim() |> String.downcase()
      {:commit, &set(&1, api, project, skill, on)}
    end
  end

  def execute(_args, _api), do: {:error, "on must be true or false."}

  defp set(tx, api, project, name, on) do
    with :ok <- Assistant.may_act_tx(tx, api.task, :change),
         {:ok, skill} <- find_skill(name),
         :ok <- toggle(tx, skill, {:project, project.id}, on) do
      {:ok, Readout.skill_set(skill.name, project.slug, on),
       %{
         "project_id" => project.id,
         "slug" => project.slug,
         "skill" => skill.name,
         "on" => on
       }}
    end
  end

  defp find_skill(name) do
    case Skills.get_by_name(name) do
      %Skill{} = skill ->
        {:ok, skill}

      nil ->
        unknown(name)
    end
  end

  defp unknown(name),
    do: {:error, Readout.unknown_skill(name, Enum.map(Skills.list(), & &1.skill.name))}

  defp toggle(tx, skill, scope, true) do
    case Skills.enable_tx(tx, skill.id, scope) do
      :ok -> :ok
      {:error, :not_found} -> unknown(skill.name)
      {:error, message} -> {:error, message}
    end
  end

  defp toggle(tx, skill, scope, false), do: Skills.disable_tx(tx, skill.id, scope)
end
