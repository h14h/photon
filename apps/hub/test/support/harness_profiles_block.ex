defmodule Photon.HarnessProfiles.Block do
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
  def respond(request) do
    last = List.last(request[:messages])

    case {last["role"], Message.text_of(last), Mock.last_user_text(request)} do
      {"user", "block", _} ->
        hold()
        Message.assistant("released")

      {"user", text, _} when text in ["block wait", "block wait block"] ->
        hold()
        Message.assistant("", [Mock.call("wait", %{})])

      {"tool", _, "block wait block"} ->
        hold()
        Message.assistant("released")

      _ ->
        Photon.TestProfile.respond(request)
    end
  end

  defp hold do
    send(Application.fetch_env!(:photon, :test_listener), {:model_request, self()})

    receive do
      :release -> :ok
    end
  end
end
