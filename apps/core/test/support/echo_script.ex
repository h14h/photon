defmodule PhotonCore.EchoScript do
  @moduledoc """
  A mock model script for tests, keyed on the latest prompt: `fail` answers
  with an error, `call <name>` makes one tool call named `<name>`, and
  anything else is echoed back as `you said <prompt>`.
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  @behaviour PhotonCore.LLM.Mock

  alias PhotonCore.LLM.Mock
  alias PhotonCore.Message

  @impl true
  def respond(request), do: request |> Mock.last_user_text() |> reply()

  defp reply("fail"), do: {:error, "scripted failure"}

  defp reply("call " <> name),
    do:
      Message.assistant("Calling.", [%{"id" => "c1", "name" => name, "arguments" => ~s({"x":1})}])

  defp reply(prompt), do: Message.assistant("you said " <> prompt)
end
