defmodule Photon.Property.SlowProfile do
  @moduledoc """
  `Photon.TestProfile` with a model that takes a moment to answer, so
  property tests can restart the harness while a model request is in flight.
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  @behaviour Photon.Durable.Profile
  @behaviour PhotonCore.LLM.Mock

  @latency_ms 25

  @impl Photon.Durable.Profile
  def llm(_conversation),
    do: %{config: %{provider: "mock", script: __MODULE__}, model: "test", reasoning: nil}

  @impl Photon.Durable.Profile
  def system_prompt(conversation), do: Photon.TestProfile.system_prompt(conversation)

  @impl Photon.Durable.Profile
  def tools(conversation), do: Photon.TestProfile.tools(conversation)

  # Simulated model latency, not test synchronization.
  @impl PhotonCore.LLM.Mock
  def respond(request) do
    Process.sleep(@latency_ms)
    Photon.TestProfile.respond(request)
  end
end
