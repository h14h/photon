defmodule Photon.HarnessProfiles.Loop do
  @moduledoc "See `Photon.HarnessProfiles`."

  @behaviour Photon.Durable.Profile
  @behaviour PhotonCore.LLM.Mock

  alias PhotonCore.LLM.Mock
  alias PhotonCore.Message

  @impl Photon.Durable.Profile
  def llm(_conversation),
    do: %{config: %{provider: "mock", script: __MODULE__}, model: "test", reasoning: nil}

  @impl Photon.Durable.Profile
  def system_prompt(conversation), do: Photon.TestProfile.system_prompt(conversation)

  @impl Photon.Durable.Profile
  def tools(conversation), do: Photon.TestProfile.tools(conversation)

  @impl PhotonCore.LLM.Mock
  def respond(_request), do: Message.assistant("", [Mock.call("wait", %{})])
end
