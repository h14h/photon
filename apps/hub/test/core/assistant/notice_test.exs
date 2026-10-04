defmodule Photon.Assistant.NoticeTest do
  @moduledoc "What Blip says without being asked."

  use Photon.Case, async: true

  defp session(id, status, fields \\ %{}) do
    Map.merge(
      %{
        id: id,
        node_id: "kepler",
        title: "Backup",
        origin: "user",
        status: status,
        last_failure: nil
      },
      fields
    )
  end

  describe "from the conversation" do
    test "says each answer with words, and each failure" do
      entries = [
        user_entry("check disks"),
        assistant_entry("", [call("list_nodes", %{}, "c1")]),
        assistant_entry("## Disks\n\n**kepler** has 40 GB free."),
        entry("error", %{"message" => "HTTP 401"})
      ]

      assert Notice.from_entries(entries) == [
               %{kind: :reply, text: "**kepler** has 40 GB free.", session_id: nil},
               %{kind: :error, text: "HTTP 401", session_id: nil}
             ]
    end

    test "a stopped run or a notice is nothing to say" do
      assert Notice.from_entries([
               entry("error", %{"message" => "Stopped.", "stopped" => true}),
               entry("error", %{"message" => "Skipped.", "notice" => true})
             ]) == []
    end
  end

  describe "the user's own node work" do
    test "says it failed, once, when it was working before" do
      before =
        Notice.statuses([
          session("a", "running"),
          session("b", "pending"),
          session("c", "idle"),
          session("d", "running", %{origin: "assistant"})
        ])

      assert before == %{"a" => :active, "b" => :active, "c" => :other}

      now = [
        session("a", "idle", %{last_failure: "disk full"}),
        session("b", "failed"),
        session("c", "idle", %{last_failure: "old news"}),
        session("d", "failed", %{origin: "assistant"})
      ]

      assert [
               %{kind: :failed, session_id: "a", text: ~s(kepler couldn't finish "Backup".)},
               %{kind: :failed, session_id: "b"}
             ] = Notice.failures(before, now)

      assert Notice.failures(Notice.statuses(now), now) == []
    end

    test "work that went fine is nothing to say" do
      before = Notice.statuses([session("a", "running")])
      assert Notice.failures(before, [session("a", "idle")]) == []
      assert Notice.failures(before, [session("a", "stopped")]) == []
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
