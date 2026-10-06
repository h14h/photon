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

  describe "tool results from earlier runs" do
    @full_output "Full output: /data/ops/op_1/out and /data/ops/op_1/err on mm1, kept for 7 days."

    defp image, do: Message.image("image/png", String.duplicate("A", 50_000))

    # Two turns, each with a long shell result and an image result.
    defp conversation do
      long = String.duplicate("é", 3_000) <> String.duplicate("x", 6_000) <> "end"

      [
        user_entry("look", seq: 1),
        assistant_entry("", [call("shell", %{}, "c1"), call("view_image", %{}, "c2")], seq: 2),
        tool_result_entry("c1", long, details: %{"full_output" => @full_output}, seq: 3),
        tool_result_entry("c2", [Message.text("1024x768"), image()], seq: 4),
        assistant_entry("done", [], seq: 5),
        user_entry("again", seq: 6),
        assistant_entry("", [call("shell", %{}, "c3"), call("view_image", %{}, "c4")], seq: 7),
        tool_result_entry("c3", long, details: %{"full_output" => @full_output}, seq: 8),
        tool_result_entry("c4", [Message.text("1024x768"), image()], seq: 9)
      ]
    end

    defp result(messages, id), do: Enum.find(messages, &(&1["tool_call_id"] == id))

    test "keep the ends of long text, with the full_output hint" do
      text = conversation() |> Context.messages() |> result("c1") |> Message.text_of()

      assert String.starts_with?(text, String.duplicate("é", 2_000) <> "\n\n...")
      assert String.ends_with?(text, "...\n\n" <> String.duplicate("x", 1_997) <> "end")
      assert text =~ "5003 characters of this older result left out. " <> @full_output
      assert length(String.to_charlist(text)) < 4_300
    end

    test "say so without a hint when the tool set none" do
      long = String.duplicate("y", 5_000)

      entries = [
        assistant_entry("", [call("shell", %{}, "c1")], seq: 1),
        tool_result_entry("c1", long, seq: 2),
        user_entry("next", seq: 3)
      ]

      text = entries |> Context.messages() |> result("c1") |> Message.text_of()
      assert text =~ "...1000 characters of this older result left out...\n\n"
    end

    test "drop images and keep their dimensions line" do
      older = conversation() |> Context.messages() |> result("c2")

      assert Message.images(older) == []
      assert Message.text_of(older) =~ "1024x768"
      assert Message.text_of(older) =~ "(image no longer shown; call view_image again to see it)"
    end

    test "leave the current turn whole" do
      entries = conversation()
      messages = Context.messages(entries)

      assert result(messages, "c3") == Enum.at(entries, 7).data["message"]
      assert result(messages, "c4") == Enum.at(entries, 8).data["message"]
    end

    # A steer placed after a tool round is a user entry partway through
    # the run; the round's results are what the model just asked for.
    test "leave a run whole when a steer comes partway through it" do
      long = String.duplicate("z", 9_000)

      entries = [
        user_entry("on mm1: look at /tmp/shot.png", seq: 1),
        assistant_entry("", [call("view_image", %{}, "c1"), call("shell", %{}, "c2")], seq: 2),
        tool_result_entry("c1", [Message.text("1024x768"), image()], seq: 3),
        tool_result_entry("c2", long, seq: 4),
        user_entry("what does the error dialog say?", seq: 5)
      ]

      messages = Context.messages(entries)
      assert result(messages, "c1") == Enum.at(entries, 2).data["message"]
      assert result(messages, "c2") == Enum.at(entries, 3).data["message"]
    end

    test "shorten a run that ended in an error once the next one starts" do
      long = String.duplicate("z", 9_000)

      entries = [
        user_entry("check", seq: 1),
        assistant_entry("", [call("shell", %{}, "c1")], seq: 2),
        tool_result_entry("c1", long, seq: 3),
        entry("error", %{"message" => "Stopped.", "stopped" => true}, id: "e_4", seq: 4),
        entry("error", %{"message" => "Skipped.", "notice" => true}, id: "e_5", seq: 5),
        user_entry("again", seq: 6),
        assistant_entry("", [call("shell", %{}, "c2")], seq: 7),
        tool_result_entry("c2", long, seq: 8),
        entry("error", %{"message" => "Skipped.", "notice" => true}, id: "e_9", seq: 9),
        user_entry("and a steer", seq: 10)
      ]

      messages = Context.messages(entries)
      assert Message.text_of(result(messages, "c1")) =~ "characters of this older result left out"
      # A notice isn't the end of a run, so the steer after it isn't a new one.
      assert result(messages, "c2") == Enum.at(entries, 7).data["message"]
    end

    test "still pair every call with its result" do
      messages = Context.messages(conversation())

      assert Enum.map(messages, &(&1["tool_call_id"] || &1["role"])) ==
               ~w(user assistant c1 c2 assistant user assistant c3 c4)
    end
  end
end
