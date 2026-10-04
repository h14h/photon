defmodule Photon.Durable.ContextTest do
  @moduledoc """
  Model input from a transcript, by example. The properties in
  `test/property/durable_context_property_test.exs` check the same rules on
  generated transcripts.
  """

  use Photon.Case, async: true

  test "sends user, assistant and tool messages, and keeps errors to the page" do
    entries = [
      user_entry("hi", seq: 1),
      entry("error", %{"message" => "model down"}, id: "e_2", seq: 2),
      assistant_entry("hello", [], id: "e_3", seq: 3)
    ]

    assert Context.messages(entries) == [Message.user("hi"), Message.assistant("hello")]
  end

  test "sees nothing before the newest reset, which carries its handoff note" do
    entries = [
      user_entry("old", seq: 1),
      entry("reset", %{"handoff" => "they like tea"}, id: "e_2", seq: 2),
      user_entry("new", id: "e_3", seq: 3)
    ]

    assert [note, new] = Context.messages(entries)
    assert Message.text_of(note) =~ "they like tea"
    assert new == Message.user("new")
  end

  test "a reset without a note just starts over" do
    entries = [user_entry("old", seq: 1), entry("reset", %{"handoff" => nil}, id: "e_2", seq: 2)]
    assert Context.messages(entries) == []
  end

  test "a call whose result never landed gets an interrupted one" do
    entries = [
      assistant_entry("", [call("wait", %{}, "c1"), call("wait", %{}, "c2")], seq: 1),
      tool_result_entry("c2", "went", id: "e_2", seq: 2)
    ]

    assert [_assistant, interrupted, went] = Context.messages(entries)
    assert interrupted["tool_call_id"] == "c1"
    assert Message.text_of(interrupted) =~ "interrupted"
    assert went == Message.tool_result("c2", "went")
  end

  test "a result without its call is dropped" do
    assert Context.messages([tool_result_entry("c9", "stray")]) == []
  end
end
