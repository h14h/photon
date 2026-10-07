defmodule Photon.Activity.RulesTest do
  @moduledoc """
  The activity log's words (sections 6.2 and 6.3 of
  `docs/plans/step-4-blip-as-coordinator.md`): each tool's summary, the
  endings, garbage calls, the message line, `changes?/1` and who asked.
  """

  use Photon.Case, async: true

  alias Photon.Activity.Rules

  defp tool_call(name, args), do: %{"id" => "call_1", "name" => name, "arguments" => args}

  defp ok(name, args, details \\ %{}), do: Rules.summary(tool_call(name, args), "ok", details)

  @pump %{"thread_id" => "c_1", "title" => "Fix the pump", "project_id" => "p_1"}
  @garden %{"project_id" => "p_1", "slug" => "garden"}

  describe "summary/3" do
    test "the machine tools" do
      assert ok("shell", %{"machine" => "mm1", "command" => "df -h"}) == "Ran `df -h` on mm1"

      assert ok("view_image", %{"machine" => "mp1", "path" => "shots/pump.png"}) ==
               "Looked at shots/pump.png on mp1"

      assert ok("list_machines", %{}) == "Checked your machines"
    end

    test "a long or multi-line command is put on one line and cut" do
      command = "cd /srv &&\n  " <> String.duplicate("make all ", 40)
      summary = ok("shell", %{"machine" => "mm1", "command" => command})

      assert summary =~ ~r/\ARan `cd \/srv && make all make all .*\.\.\.` on mm1\z/
      assert String.length(summary) <= 200
    end

    test "reading projects and threads" do
      assert ok("list_projects", %{}) == "Listed projects"
      assert ok("list_threads", %{}) == "Listed threads"
      assert ok("list_threads", %{"project" => "garden"}, @garden) == "Listed threads in garden"
      assert ok("read_project", %{"project" => "p_1"}, @garden) == "Looked over garden"
      assert ok("read_project", %{"project" => "garden"}) == "Looked over garden"
      assert ok("read_thread", %{"thread" => "c_1"}, @pump) == ~s(Read "Fix the pump")
      assert ok("read_thread", %{"thread" => "c_1"}) == "Read c_1"
    end

    test "starting, messaging and stopping work" do
      assert ok("start_project", %{"purpose" => "Grow food."}, %{"slug" => "garden"}) ==
               "Started the project garden"

      assert ok("start_project", %{"purpose" => "Grow food."}) == "Started a project"

      started = Map.merge(@garden, %{"thread_id" => "c_2", "title" => "Check the backups"})

      assert ok("start_thread", %{"project" => "garden", "message" => "check"}, started) ==
               ~s(Started "Check the backups" in garden)

      assert ok("start_thread", %{"project" => "garden", "message" => "check"}) ==
               "Started a thread in garden"

      assert ok("message_thread", %{"thread" => "c_1", "message" => "go"}, @pump) ==
               ~s(Messaged "Fix the pump")

      assert ok("message_thread", %{"thread" => "c_1", "message" => "go"}) == "Messaged c_1"
      assert ok("stop_thread", %{"thread" => "c_1"}, @pump) == ~s(Stopped "Fix the pump")
    end

    test "a call on one thread, worded again with the thread's title now" do
      assert Rules.thread_summary("read_thread", "ok", "Fix the pump", nil) ==
               ~s(Read "Fix the pump")

      assert Rules.thread_summary("start_thread", "ok", "Fix the pump", "garden") ==
               ~s(Started "Fix the pump" in garden)

      assert Rules.thread_summary("start_thread", "ok", "Fix the pump", nil) ==
               ~s(Started "Fix the pump")

      assert Rules.thread_summary("message_thread", "ok", "Fix\nthe  pump", nil) ==
               ~s(Messaged "Fix the pump")

      assert Rules.thread_summary("stop_thread", "aborted", "Fix the pump", nil) ==
               ~s(Stopped "Fix the pump": stopped)

      # Other tools, or no title, have nothing to word again.
      assert Rules.thread_summary("shell", "ok", "Fix the pump", nil) == nil
      assert Rules.thread_summary("read_thread", "ok", nil, nil) == nil
    end

    test "context files" do
      file = Map.put(@garden, "file", "notes.md")
      args = %{"project" => "garden", "name" => "Notes.md"}

      assert ok("list_context_files", %{"project" => "garden"}) == "Listed the files in garden"
      assert ok("read_context_file", args, @garden) == "Read Notes.md in garden"

      assert ok("write_context_file", Map.put(args, "content", "hi"), file) ==
               "Wrote notes.md in garden"

      edit = Map.merge(args, %{"old_text" => "a", "new_text" => "b"})
      assert ok("edit_context_file", edit, file) == "Edited notes.md in garden"

      assert ok("edit_context_file", Map.delete(edit, "new_text"), file) ==
               "Used edit_context_file"
    end

    test "questions" do
      args = %{"question_id" => "q_1", "answer" => "staging"}
      assert ok("answer_question", args, @pump) == "Answered: staging"
      assert ok("answer_question", args) == "Answered: staging"

      assert ok("ask_owner", %{
               "question_id" => "q_1",
               "question" => "Which pump model should I order?"
             }) == "Asked you: Which pump model should I order?"
    end

    test "schedules and skills" do
      daily = %{"prompt" => "check the pump", "every_minutes" => 1440, "project" => "garden"}
      assert ok("schedule", daily, @garden) == ~s(Scheduled "check the pump" every day in garden)

      assert ok("schedule", %{"prompt" => "call the plumber", "in_minutes" => 30}) ==
               ~s(Scheduled "call the plumber" in 30 minutes)

      assert ok("schedule", %{"prompt" => "p", "every_minutes" => 120}) ==
               ~s(Scheduled "p" every 2 hours)

      assert ok("schedule", %{"prompt" => "p", "at" => "2026-10-08T09:00:00Z"}) ==
               ~s(Scheduled "p" at 2026-10-08T09:00:00Z)

      assert ok("schedule", %{"prompt" => "p"}) == ~s(Scheduled "p")
      assert ok("schedule", %{"prompt" => "p", "in_minutes" => "soon"}) == "Used schedule"

      assert ok("list_schedules", %{}) == "Checked the schedules"
      assert ok("list_schedules", %{"project" => "garden"}) == "Checked the schedules in garden"
      assert ok("cancel_schedule", %{"schedule_id" => "sc_9"}) == "Cancelled sc_9"

      assert ok("cancel_schedule", %{"schedule_id" => "sc_9"}, @garden) ==
               "Cancelled sc_9 in garden"

      assert ok("list_skills", %{}) == "Checked skills"

      on = %{"project" => "garden", "skill" => "pdf-forms", "on" => true}
      assert ok("set_project_skill", on) == "Turned on pdf-forms for garden"

      assert ok("set_project_skill", %{on | "on" => false}, @garden) ==
               "Turned off pdf-forms for garden"

      assert ok("load_skill", %{"name" => "pdf-forms"}) == "Loaded the pdf-forms skill"
    end

    test "memory" do
      assert ok("update_memory", %{"action" => "add", "text" => "prefers metric units"}) ==
               "Remembered: prefers metric units"

      assert ok("update_memory", %{"action" => "remove", "text" => "old"}) == "Forgot: old"

      assert ok("update_memory", %{"action" => "rewrite", "text" => "all"}) ==
               "Rewrote its memory"

      assert ok("update_memory", %{"action" => "shout", "text" => "x"}) == "Used update_memory"
    end

    test "arguments as the model's JSON string" do
      json = Jason.encode!(%{"machine" => "mm1", "command" => "uptime"})
      assert ok("shell", json) == "Ran `uptime` on mm1"
    end

    test "a failed, stopped or interrupted call says so" do
      args = %{"machine" => "mm1", "command" => "df -h"}
      assert Rules.summary(tool_call("shell", args), "error", %{}) == "Ran `df -h` on mm1: failed"

      assert Rules.summary(tool_call("shell", args), "aborted", %{}) ==
               "Ran `df -h` on mm1: stopped"

      assert Rules.summary(tool_call("shell", args), "interrupted", %{}) ==
               "Ran `df -h` on mm1: interrupted"

      assert Rules.summary(tool_call("mystery", "{"), "aborted", nil) == "Used mystery: stopped"
    end

    test "the ending stays on a summary that is cut" do
      question = String.duplicate("why ", 100)

      summary =
        Rules.summary(
          tool_call("ask_owner", %{"question_id" => "q", "question" => question}),
          "error",
          %{}
        )

      assert String.length(summary) <= 200
      assert String.ends_with?(summary, "...: failed")
    end

    test "garbage calls give Used <name>" do
      assert ok("shell", "not json") == "Used shell"
      assert ok("shell", "[1, 2]") == "Used shell"
      assert ok("shell", %{"machine" => "mm1", "command" => 5}) == "Used shell"
      assert Rules.summary(%{"name" => "shell"}, "ok", %{}) == "Used shell"
      assert ok("read_thread", %{"thread" => nil}) == "Used read_thread"
      assert ok("list_threads", %{"project" => 7}) == "Used list_threads"

      assert ok("set_project_skill", %{"project" => "g", "skill" => "s", "on" => "yes"}) ==
               "Used set_project_skill"
    end

    test "an unknown tool, a missing name, and calls that aren't maps" do
      assert ok("summon_dragon", %{}) == "Used summon_dragon"
      assert Rules.summary(%{"arguments" => %{}}, "ok", %{}) == "Used a tool"
      assert Rules.summary(nil, nil, nil) == "Used a tool"
      assert Rules.summary("shell", "ok", []) == "Used a tool"
      assert Rules.summary(%{"name" => 5, "arguments" => 5}, "ok", "x") == "Used a tool"
    end

    test "details with atom keys or of the wrong type are read or ignored" do
      args = %{"thread" => "c_1"}
      assert ok("read_thread", args, %{title: "Fix the pump"}) == ~s(Read "Fix the pump")
      assert ok("read_thread", args, %{"title" => 5}) == "Read c_1"
      assert ok("read_thread", args, "details") == "Read c_1"
    end
  end

  describe "message_summary/1" do
    test "the first line with words in it" do
      assert Rules.message_summary("\n  \nFix the pump in Garden finished.\nMore.") ==
               "Told you: Fix the pump in Garden finished."
    end

    test "a long line is cut to 200 characters" do
      summary = Rules.message_summary(String.duplicate("word ", 100))
      assert String.length(summary) <= 200
      assert String.ends_with?(summary, "...")
    end

    test "empty text, or none" do
      assert Rules.message_summary("") == "Told you something"
      assert Rules.message_summary("  \n ") == "Told you something"
      assert Rules.message_summary(nil) == "Told you something"
    end
  end

  test "changes?/1: reads don't change anything; everything else may" do
    for name <-
          ~w(list_projects list_threads list_machines read_thread read_context_file load_skill),
        do: refute(Rules.changes?(name), name)

    for name <- ~w(shell view_image start_thread message_thread answer_question ask_owner
                   write_context_file schedule update_memory summon_dragon),
        do: assert(Rules.changes?(name), name)

    assert Rules.changes?(nil)
  end

  describe "origin_label/2" do
    @names %{"c_1" => "Fix the pump", "sc_1" => "Review the day"}

    defp label(origin, id), do: Rules.origin_label(%{origin: origin, origin_id: id}, @names)

    test "the owner, a thread's question and a schedule" do
      assert label("owner", nil) == "You"
      assert label("thread", "c_1") == "Fix the pump"
      assert label("thread", "c_gone") == "A thread"
      assert label("schedule", "sc_1") == "Schedule: Review the day"
      assert label("schedule", "sc_gone") == "A schedule"
    end

    test "a follow-up, with and without a thread" do
      assert label("follow_up", "c_1") == "Blip's follow-up on Fix the pump"
      assert label("follow_up", nil) == "Blip's follow-up"
      assert label("follow_up", "c_gone") == "Blip's follow-up"
      # A schedule Blip made for itself names no thread.
      assert label("follow_up", "sc_1") == "Blip's follow-up"
    end

    test "anything else is Blip" do
      assert label("unknown", nil) == "Blip"
      assert label("comet", "c_1") == "Blip"
      assert Rules.origin_label(nil, @names) == "Blip"
      assert Rules.origin_label(%{origin: "thread", origin_id: "c_1"}, nil) == "A thread"
    end
  end
end
