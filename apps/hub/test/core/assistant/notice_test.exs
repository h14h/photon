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
