defmodule Photon.Assistant.Tools.LoadSkill do
  @moduledoc """
  Blip's `load_skill` tool: loads one of the skills turned on for Blip,
  whose instructions become the call's result. A thread's is
  `Photon.Threads.Tools.LoadSkill`; both take their name, description and
  parameters from `Photon.Skills.Prompt`. A skill turned on for any machine
  the hub knows loads too, with that machine named.

  The skill is read inside the commit that records the result
  (`Photon.Skills.load_tx/3`), so a load racing a toggle returns either
  the text from before it or the error from after it. It changes nothing,
  so a rerun after a restart is safe.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.Skills
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
  def execute(%{"name" => name}, _api), do: {:commit, &Skills.load_tx(&1, :blip, name)}
end
