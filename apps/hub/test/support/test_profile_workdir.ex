defmodule Photon.TestProfile.Workdir do
  @moduledoc """
  `Photon.TestProfile` with a working directory: `"garden"`, or a raise
  for a conversation titled `"gone"` (as a thread whose project is
  missing raises).
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  @behaviour Photon.Durable.Profile

  @impl true
  def llm(conversation), do: Photon.TestProfile.llm(conversation)

  @impl true
  def system_prompt(conversation), do: Photon.TestProfile.system_prompt(conversation)

  @impl true
  def tools(conversation), do: Photon.TestProfile.tools(conversation)

  @impl true
  def workdir(%{title: "gone"}), do: raise("this thread's project is gone")
  def workdir(_conversation), do: "garden"
end
