defmodule Photon.MachineTools.MockPhrasesTest do
  @moduledoc "The machine phrasings and result relay the scripted models share."

  use Photon.Case, async: true

  alias Photon.MachineTools.MockPhrases

  # The reply of the first phrasing `text` matches, as the scripts try them.
  defp reply(text) do
    Enum.find_value(MockPhrases.phrasings(), fn {pattern, reply} ->
      case Regex.run(pattern, text, capture: :all_but_first) do
        nil -> nil
        captures -> reply.(captures)
      end
    end)
  end

  defp calls(nil), do: nil

  defp calls(message),
    do:
      Enum.map(Message.tool_calls(message), fn call ->
        {:ok, args} = Message.arguments(call)
        {call["name"], args}
      end)

  test "each phrasing makes its tool call" do
    assert calls(reply("machines")) == [{"list_machines", %{}}]
    assert calls(reply("list machines")) == [{"list_machines", %{}}]

    assert calls(reply("on mp1: $ uptime ")) ==
             [{"shell", %{"machine" => "mp1", "command" => "uptime"}}]

    assert calls(reply("on mm1: look at shots/a.png")) ==
             [{"view_image", %{"machine" => "mm1", "path" => "shots/a.png"}}]

    assert Message.text_of(reply("on mp1: $ uptime")) == "Running that on mp1."
  end

  test "anything else matches none of them" do
    assert reply("on mp1: check the backups") == nil
    assert reply("remember the NAS is mp1") == nil
  end

  test "relays a result, an error and an image" do
    assert MockPhrases.relay_result(Message.tool_result("c1", "hello")) == "hello"

    assert MockPhrases.relay_result(Message.tool_result("c1", "a\n\nb\n")) ==
             "```\na\nb\n```"

    assert MockPhrases.relay_result(Message.tool_result("c1", "```\nx")) == "````\n```\nx\n````"

    assert MockPhrases.relay_result(Message.tool_result("c1", "Error: mm1 is offline")) ==
             "That didn't work: mm1 is offline"

    image =
      Message.tool_result("c1", [
        Message.image("image/png", "iVBORw0KGgo="),
        Message.text("1x1 image/png, /tmp/dot.png on local")
      ])

    assert MockPhrases.relay_result(image) ==
             "Here it is.\n\n1x1 image/png, /tmp/dot.png on local"
  end
end
