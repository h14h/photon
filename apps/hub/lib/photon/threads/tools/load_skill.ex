defmodule Photon.Threads.Tools.LoadSkill do
  @moduledoc """
  A thread's `load_skill` tool (section 2.6 of
  `docs/plans/step-3-skills-and-schedules.md`): loads one of the skills
  turned on for the thread's project, whose instructions become the call's
  result. Blip's is `Photon.Assistant.Tools.LoadSkill`; the two differ
  only in the scope, which comes from the conversation, and take their
  name, description and parameters from `Photon.Skills.Prompt`. A skill
  turned on for any machine the hub knows loads too, with that machine
  named (section 4 of `docs/plans/machine-skills.md`).

  The skill is read inside the commit that records the result
  (`Photon.Skills.load_tx/3`), so a load racing a toggle returns either
  the text from before it or the error from after it. It changes nothing,
  so a rerun after a restart is safe.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.{Skills, Threads}
  alias Photon.Skills.Prompt

  @impl true
  def name, do: Prompt.tool_name()

  @impl true
  def description, do: Prompt.tool_description()

  @impl true
  def parameters, do: Prompt.tool_parameters()

  @impl true
  def replay, do: :safe

  @impl true
  def execute(%{"name" => name}, api) do
    scope = {:project, Threads.project_id!(api.conversation_id)}
    {:commit, &Skills.load_tx(&1, scope, name)}
  end
end
