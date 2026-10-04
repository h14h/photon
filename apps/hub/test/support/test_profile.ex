defmodule Photon.TestProfile do
  @moduledoc """
  A conversation profile for harness tests: a scripted model and a `wait`
  tool that parks durably until the signal `"go"` fires.

    * `"wait"` calls the wait tool, then answers `"waited"`
    * `"fail"` makes the model request fail
    * anything else is echoed as `"echo: <text>"`
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  @behaviour Photon.Durable.Profile
  @behaviour PhotonCore.LLM.Mock

  alias PhotonCore.LLM.Mock
  alias PhotonCore.Message

  @impl Photon.Durable.Profile
  def llm(_conversation),
    do: %{config: %{provider: "mock", script: __MODULE__}, model: "test", reasoning: nil}

  @impl Photon.Durable.Profile
  def system_prompt(_conversation), do: "test"

  @impl Photon.Durable.Profile
  def tools(_conversation), do: [Photon.TestProfile.Wait]

  @impl PhotonCore.LLM.Mock
  def respond(request) do
    case List.last(request[:messages]) do
      %{"role" => "tool"} -> Message.assistant("waited")
      message -> reply(Message.text_of(message))
    end
  end

  defp reply("wait"), do: Message.assistant("", [Mock.call("wait", %{})])
  defp reply("fail"), do: {:error, "model down"}
  defp reply(text), do: Message.assistant("echo: " <> text)
end
