defmodule Photon.TestProfile do
  @moduledoc """
  A conversation profile for harness tests: a scripted model, a `wait`
  tool that parks durably until the signal `"go"` fires, a `raise` tool
  that raises, and a `shell_then_raise` tool that starts a shell op like
  `shell` and raises when it resumes.

    * `"wait"` calls the wait tool, then answers `"waited"`
    * `"raise"` calls the raise tool, then answers `"waited"`
    * `"where"` calls the `where` tool, which reports the call's working
      directory once `"go"` fires, then answers `"waited"`
    * `"shell then raise on <machine>"` calls `shell_then_raise` there,
      then answers `"waited"`
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
  def tools(_conversation),
    do: [
      Photon.TestProfile.Wait,
      Photon.TestProfile.Raise,
      Photon.TestProfile.ShellThenRaise,
      Photon.TestProfile.Where
    ]

  @impl PhotonCore.LLM.Mock
  def respond(request) do
    case List.last(request[:messages]) do
      %{"role" => "tool"} -> Message.assistant("waited")
      message -> reply(Message.text_of(message))
    end
  end

  defp reply("wait"), do: Message.assistant("", [Mock.call("wait", %{})])
  defp reply("raise"), do: Message.assistant("", [Mock.call("raise", %{})])
  defp reply("where"), do: Message.assistant("", [Mock.call("where", %{})])

  defp reply("shell then raise on " <> machine),
    do:
      Message.assistant("", [
        Mock.call("shell_then_raise", %{"machine" => machine, "command" => "sleep 30"})
      ])

  defp reply("fail"), do: {:error, "model down"}
  defp reply(text), do: Message.assistant("echo: " <> text)
end
