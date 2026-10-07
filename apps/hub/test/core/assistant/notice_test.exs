defmodule Photon.Assistant.NoticeTest do
  @moduledoc "What Blip says without being asked."

  use Photon.Case, async: true

  describe "from the conversation" do
    test "says each answer with words, and each failure" do
      entries = [
        user_entry("check disks"),
        assistant_entry("", [call("list_machines", %{}, "c1")]),
        assistant_entry("## Disks\n\n**kepler** has 40 GB free."),
        entry("error", %{"message" => "HTTP 401"})
      ]

      assert Notice.from_entries(entries) == [
               %{kind: :reply, text: "**kepler** has 40 GB free."},
               %{kind: :error, text: "HTTP 401"}
             ]
    end

    test "a stopped run or a notice is nothing to say" do
      assert Notice.from_entries([
               entry("error", %{"message" => "Stopped.", "stopped" => true}),
               entry("error", %{"message" => "Skipped.", "notice" => true})
             ]) == []
    end
  end

  describe "a thread's question" do
    defp ask_owner(status, details) do
      result = tool_result_entry("c1", "Asked the user.", status: status, details: details)
      put_in(result.data["name"], "ask_owner")
    end

    test "an ok ask_owner result says the question in Blip's words; a refused one says nothing" do
      details = %{
        "question_id" => "q_1",
        "title" => "Fix the pump",
        "wording" => "Which\nbranch?"
      }

      assert Notice.from_entries([ask_owner("ok", details)]) == [
               %{kind: :question, text: ~s("Fix the pump" asks: Which branch?)}
             ]

      assert Notice.from_entries([ask_owner("error", %{})]) == []
    end

    test "the hub's escalation notice says the thread's own question" do
      notice =
        entry("error", %{
          "message" =>
            ~s(Here's "Gate"'s question as the thread asked it. Your answer goes straight to it.),
          "notice" => true,
          "question_id" => "q_2",
          "question_notice" => "escalated",
          "title" => "Gate",
          "question" => "Is it locked?"
        })

      assert Notice.from_entries([notice]) == [
               %{kind: :question, text: ~s("Gate" asks: Is it locked?)}
             ]

      withdrawn = put_in(notice.data["question_notice"], "withdrawn")
      assert Notice.from_entries([withdrawn]) == []
    end

    test "a long question is cut, and one with no words still says there is one" do
      long = String.duplicate("word ", 100)
      details = %{"question_id" => "q_1", "title" => "Gate", "wording" => long}
      assert [%{text: text}] = Notice.from_entries([ask_owner("ok", details)])
      assert String.length(text) == String.length(~s("Gate" asks: )) + 280
      assert String.ends_with?(text, "...")

      assert Notice.from_entries([ask_owner("ok", %{"question_id" => "q_1"})]) == [
               %{kind: :question, text: "A thread has a question for you."}
             ]
    end

    test "a signal message is nothing to say; Blip's reply to it is" do
      signal =
        entry("user", %{
          "message" => Message.user(~s{[Thread update] Garden / "Pump" (c_1) failed.}),
          "source" => %{"kind" => "signal", "signals" => [%{"kind" => "thread_update"}]}
        })

      assert Notice.from_entries([signal, assistant_entry("Pump failed.")]) == [
               %{kind: :reply, text: "Pump failed."}
             ]
    end

    defp question_signal do
      entry("user", %{
        "message" => Message.user("[Question q_1 from Garden / \"Deploy\" (c_1)]\nWhich branch?"),
        "source" => %{
          "kind" => "signal",
          "signals" => [%{"kind" => "question", "question_id" => "q_1", "thread_id" => "c_1"}]
        }
      })
    end

    test "Blip's replies in a run that only handles questions say nothing; its question does" do
      details = %{"question_id" => "q_1", "title" => "Deploy", "wording" => "Which branch?"}

      # The run arrives over three batches, as its commits do.
      {first, state} =
        Notice.scan(
          [question_signal(), assistant_entry("Asking you.", [call("ask_owner", %{}, "c1")])],
          Notice.initial()
        )

      {second, state} = Notice.scan([ask_owner("ok", details)], state)
      {third, state} = Notice.scan([assistant_entry("Asked the user.")], state)

      assert first == []
      assert second == [%{kind: :question, text: ~s("Deploy" asks: Which branch?)}]
      assert third == []

      # The owner's next message starts a run of theirs, which speaks.
      {said, _state} =
        Notice.scan([user_entry("check disks"), assistant_entry("All fine.")], state)

      assert said == [%{kind: :reply, text: "All fine."}]
    end

    test "a run with an update, or the owner's steer, beside the question speaks" do
      update =
        entry("user", %{
          "message" => Message.user("[Thread update] Garden / \"Pump\" (c_2) failed."),
          "source" => %{"kind" => "signal", "signals" => [%{"kind" => "thread_update"}]}
        })

      steered = [
        question_signal(),
        assistant_entry("", [call("answer_question", %{}, "c1")]),
        tool_result_entry("c1", "Sent your answer."),
        user_entry("and check disks"),
        assistant_entry("Answered, and the disks are fine.")
      ]

      for entries <- [[question_signal(), update, assistant_entry("Pump failed.")], steered] do
        assert [%{kind: :reply}] = Notice.from_entries(entries)
      end
    end
  end

  describe "the paragraph in the bubble" do
    test "is the first block with words, whole, as Markdown" do
      text = "Checked kepler. The disk is **82%** full,\nmostly `/var/log`.\n\n- one\n- two"

      assert Notice.paragraph(text) ==
               "Checked kepler. The disk is **82%** full,\nmostly `/var/log`."

      assert Notice.paragraph(String.duplicate("word ", 200)) =~ String.duplicate("word ", 199)
    end

    test "leaves out headings, even with no blank line under them" do
      assert Notice.paragraph("## Disks\n\nAll fine.") == "All fine."
      assert Notice.paragraph("# Disks\nAll fine.\n\nMore.") == "All fine."
      assert Notice.paragraph("#hashtag is text") == "#hashtag is text"
    end

    test "is nothing when there are no words" do
      assert Notice.paragraph("  \n\n   ") == ""
      assert Notice.paragraph("## Only a title") == ""
    end
  end
end
