defmodule Photon.Assistant.ReadoutTest do
  @moduledoc "The texts Blip's read tools return, from rows and board entries built here."

  use Photon.Case, async: true

  import Photon.Fixtures, only: [call: 3]

  alias Photon.Assistant.Readout
  alias Photon.Questions.Question
  alias Photon.Threads.Thread

  @now ~U[2026-10-07 12:00:00Z]
  @garden %{id: "p_1", slug: "garden", name: "Garden"}

  defp project(overrides \\ []) do
    Map.merge(
      Map.put(
        @garden,
        :purpose,
        "Keep the vegetable beds watered and the pump running. Check the soil weekly."
      ),
      Map.new(overrides)
    )
  end

  defp thread(id, title, fields \\ []) do
    struct!(
      %Thread{id: id, project_id: "p_1", title: title, active_at: ~U[2026-10-07 09:00:00Z]},
      fields
    )
  end

  defp entry(thread, state, questions \\ [], project \\ @garden),
    do: %{id: thread.id, thread: thread, project: project, state: state, questions: questions}

  defp question(id, status, text),
    do: %Question{id: id, status: status, question: text, thread_id: "c_1"}

  describe "list_projects" do
    test "a line per project: its name, purpose's first sentence, thread states and files" do
      house = %{id: "p_2", slug: "house", name: "House!", purpose: "Fix things"}

      board = [
        entry(thread("c_1", "Fix the pump"), :running),
        entry(thread("c_2", "Order seeds"), :waiting),
        entry(thread("c_3", "A"), :idle),
        entry(thread("c_4", "B"), :idle),
        entry(thread("c_5", "C"), :unread)
      ]

      assert Readout.projects([project(), house], board, %{"p_1" => 3, "p_2" => 1}) ==
               "garden: Garden. Keep the vegetable beds watered and the pump running. " <>
                 "1 running, 1 waiting on the user, 1 finished and not yet seen by the user, " <>
                 "2 idle. 3 context files.\n" <>
                 "house: House! Fix things. No threads. 1 context file."

      assert Readout.projects([], [], %{}) == "No projects yet."
      assert Readout.projects([project()], [], %{}) =~ "No threads. No context files."
    end

    test "the purpose's first sentence is cut to 120 characters at a word" do
      long = String.duplicate("water the beds ", 20) <> "now."
      [line] = String.split(Readout.projects([project(purpose: long)], [], %{}), "\n")
      ["garden: Garden. " <> sentence, _rest] = String.split(line, "... ", parts: 2)
      assert String.length(sentence) <= 117
      assert String.ends_with?(sentence, "water the")
    end
  end

  describe "read_project" do
    defp facts(overrides \\ []) do
      Map.merge(%{files: [], board: [], schedules: [], skills: []}, Map.new(overrides))
    end

    test "every list says none when empty" do
      text = Readout.project(project(), facts())

      assert text ==
               """
               Garden (garden, ID p_1)
               Purpose: Keep the vegetable beds watered and the pump running. Check the soil weekly.

               Context files: none.

               Threads: none.

               Schedules: none.

               Skills on: none.\
               """
    end

    test "files with who changed them, threads with notes, schedules with targets, skills" do
      pump =
        thread("c_1", "Fix the pump", last_run_status: "failed", last_run_note: "HTTP 500: no")

      seeds = thread("c_2", "Order seeds")

      files = [
        %{
          name: "old.md",
          content: "x",
          updated_at: ~U[2026-10-01 08:00:00Z],
          updated_by: "owner"
        },
        %{
          name: "notes.md",
          content: String.duplicate("a", 1234),
          updated_at: ~U[2026-10-07 10:30:00Z],
          updated_by: "c_1"
        },
        %{name: "plan.md", content: "", updated_at: ~U[2026-10-06 10:30:00Z], updated_by: "blip"},
        %{name: "gone.md", content: "ab", updated_at: ~U[2026-09-01 10:30:00Z], updated_by: "c_9"}
      ]

      schedules = [
        %{
          id: "sc_1",
          when: "first at 2026-10-08 09:00 UTC, then every 1440 minutes",
          state: :waiting,
          next_at: ~U[2026-10-08 09:00:00Z],
          prompt: "check  the\nbackups",
          thread_id: nil
        },
        %{
          id: "sc_2",
          when: "at 2026-10-01 09:00 UTC",
          state: :done,
          next_at: nil,
          prompt: "water",
          thread_id: "c_2"
        },
        %{
          id: "sc_3",
          when: "at 2026-10-01 09:00 UTC",
          state: {:stopped, "boom"},
          next_at: nil,
          prompt: "x",
          thread_id: "c_9"
        }
      ]

      board = [entry(pump, :failed), entry(seeds, :quiet)]

      text =
        Readout.project(
          project(),
          facts(files: files, board: board, schedules: schedules, skills: ["pdf-forms", "notes"])
        )

      assert text =~
               """
               Context files:
               - notes.md (1,234 characters, changed 2026-10-07 10:30 UTC by thread "Fix the pump")
               - plan.md (0 characters, changed 2026-10-06 10:30 UTC by you)
               - old.md (1 character, changed 2026-10-01 08:00 UTC by the user)
               - gone.md (2 characters, changed 2026-09-01 10:30 UTC by another thread)
               """

      assert text =~
               """
               Threads (2, most recent first):
               - c_1 "Fix the pump": failed: HTTP 500: no
               - c_2 "Order seeds": quiet
               """

      assert text =~
               """
               Schedules:
               - sc_1: first at 2026-10-08 09:00 UTC, then every 1440 minutes; next 2026-10-08 09:00 UTC; starts a new thread each time: "check the backups"
               - sc_2: at 2026-10-01 09:00 UTC; done, won't fire again; wakes c_2 "Order seeds": "water"
               - sc_3: at 2026-10-01 09:00 UTC; stopped after an error (boom); wakes c_9: "x"
               """

      assert String.ends_with?(text, "Skills on: pdf-forms, notes.")
    end

    test "shows 40 threads, then how many more" do
      board = for i <- 1..43, do: entry(thread("c_#{i}", "T#{i}"), :idle)
      text = Readout.project(project(), facts(board: board))
      assert text =~ "Threads (43, most recent first):"
      assert text =~ ~s(- c_40 "T40")
      refute text =~ ~s(c_41 ")
      assert text =~ "...and 3 more; list_threads with a state shows fewer."
    end
  end

  describe "list_threads" do
    @all %{project: nil, state: nil}

    test "a line per thread with its project, state and note or questions" do
      board = [
        entry(thread("c_1", "Fix the pump"), :waiting, [
          question("q_1", "with_owner", "Which pump model should I order?")
        ]),
        entry(thread("c_2", "Deploy"), :asking, [
          question("q_2", "asked", "Which branch?"),
          question("q_3", "with_owner", "Which day?")
        ]),
        entry(thread("c_3", "Tests", last_run_note: "All green."), :running),
        entry(
          thread("c_4", "Ask",
            last_run_status: "done",
            last_run_asked: true,
            last_run_note: "Shall I?"
          ),
          :waiting
        ),
        entry(
          thread("c_5", "Read",
            last_run_status: "done",
            last_run_note: "Done it.",
            last_run_ended_at: @now
          ),
          :unread
        ),
        entry(
          thread("c_6", "Old", last_run_status: "done", resolved_at: @now),
          :idle,
          [],
          %{id: "p_2", slug: "house", name: "House"}
        )
      ]

      assert Readout.threads(board, @all) ==
               """
               c_1 "Fix the pump" (garden): waiting on the user: question q_1, passed to the user: Which pump model should I order?
               c_2 "Deploy" (garden): asking you: question q_2, with you: Which branch?; question q_3, passed to the user: Which day?
               c_3 "Tests" (garden): running
               c_4 "Ask" (garden): waiting on the user: Shall I?
               c_5 "Read" (garden): finished, not yet seen by the user: Done it.
               c_6 "Old" (house): resolved\
               """
    end

    test "filters by project and state, and says when nothing matches" do
      board = [
        entry(thread("c_1", "A"), :failed),
        entry(thread("c_2", "B"), :idle),
        entry(thread("c_3", "C"), :failed, [], %{id: "p_2", slug: "house", name: "House"})
      ]

      assert Readout.threads(board, %{project: "garden", state: :failed}) ==
               ~s(c_1 "A" \(garden\): failed)

      assert Readout.threads(board, %{project: nil, state: :failed}) =~ "c_3"

      assert Readout.threads(board, %{project: "house", state: nil}) ==
               ~s(c_3 "C" \(house\): failed)

      assert Readout.threads([], @all) == "No threads."
      assert Readout.threads([], %{project: "garden", state: nil}) == "No threads in garden."

      assert Readout.threads(board, %{project: "garden", state: :waiting}) ==
               "No threads in garden are waiting on the user."
    end

    test "shows 40, then how many more" do
      board = for i <- 1..52, do: entry(thread("c_#{i}", "T#{i}"), :idle)
      lines = String.split(Readout.threads(board, @all), "\n")
      assert length(lines) == 41
      assert List.last(lines) == "...and 12 more; name a project or a state to see fewer."
    end

    test "state names" do
      assert Readout.state_names() == ~w(running asking waiting failed unread quiet idle)
      assert Readout.state_named("unread") == :unread
      assert Readout.state_named(nil) == nil
      assert Readout.state_named("nope") == nil
    end
  end

  describe "read_thread" do
    defp e(kind, data), do: %{kind: kind, data: data}

    defp user(text, kind \\ "user"),
      do: e("user", %{"message" => Message.user(text), "source" => %{"kind" => kind}})

    defp answer(text, calls \\ []),
      do: e("assistant", %{"message" => Message.assistant(text, calls)})

    defp result(call_id, name, status, text, details \\ %{}) do
      e("tool_result", %{
        "message" => Message.tool_result(call_id, text),
        "name" => name,
        "status" => status,
        "details" => details
      })
    end

    defp read(entry, entries, last \\ 20),
      do: Readout.thread(entry, entries, %{last: last, now: @now})

    test "the header: title, project, state, who started it, last activity, last run, questions" do
      t =
        thread("c_1", "Fix the pump",
          started_by: "blip",
          last_run_status: "done",
          last_run_ended_at: ~U[2026-10-07 09:05:00Z],
          last_run_note: "Which model?"
        )

      text = read(entry(t, :waiting, [question("q_1", "with_owner", "Which model?")]), [])

      assert text ==
               """
               "Fix the pump" (c_1), in Garden (garden)
               State: waiting on the user
               Started by you; last activity 2026-10-07 09:00 UTC (3 hours ago)
               Last run finished 2026-10-07 09:05 UTC: Which model?
               Open question q_1, passed to the user: Which model?

               No messages yet.\
               """

      owner = read(entry(thread("c_2", "X", active_at: ~U[2026-10-07 11:59:30Z]), :idle), [])

      assert owner =~
               "State: idle\nStarted by the user; last activity 2026-10-07 11:59 UTC (just now)\n"

      refute owner =~ "Last run"

      scheduled = read(entry(thread("c_3", "Y", started_by: "schedule"), :idle), [])
      assert scheduled =~ "Started by a schedule;"
    end

    test "each kind of item, with tool lines and no tool output" do
      shell = call("shell", %{"machine" => "mm1", "command" => "df  -h"}, "k1")
      write = call("write_context_file", %{"name" => "Notes", "content" => "secret"}, "k2")
      ask = call("ask_blip", %{"question" => "Which branch?"}, "k3")
      broken = call("shell", %{"machine" => "mm1", "command" => "boom"}, "k4")
      stopped = call("shell", %{"machine" => "mm1", "command" => "sleep 9"}, "k5")

      entries = [
        user("check the disks"),
        user("[Scheduled] water", "routine"),
        user("also the backups", "blip"),
        answer("", [shell, write, ask, broken, stopped]),
        result("k1", "shell", "ok", "Filesystem  Size\n/dev/disk1 100G", %{
          "machine" => "mm1",
          "exit_code" => 0
        }),
        result("k2", "write_context_file", "ok", "Wrote notes.md.", %{"file" => "notes.md"}),
        result("k3", "ask_blip", "ok", "Blip answered: staging"),
        result("k4", "shell", "error", "Error: mm1 has been offline\nfor 10 minutes"),
        result("k5", "shell", "aborted", "Stopped by the user before it finished."),
        result("k_gone", "shell", "ok", "out", %{"command" => "uptime", "machine" => "mp1"}),
        result("k_other", "mystery", "ok", "out"),
        answer("All done.\n\nThe disk is fine.")
      ]

      text = read(entry(thread("c_1", "Disks"), :unread), entries)
      [_header, items] = String.split(text, "\n\n", parts: 2)

      assert items ==
               """
               [user] check the disks
               [scheduled] [Scheduled] water
               [Blip] also the backups
               [tool] Ran `df -h` on mm1: exit 0
               [tool] Wrote notes.md
               [tool] Asked Blip: Which branch?
               [tool] Ran `boom` on mm1: error: mm1 has been offline for 10 minutes
               [tool] Ran `sleep 9` on mm1: stopped
               [tool] Ran `uptime` on mp1
               [tool] Used mystery
               [thread] All done.

               The disk is fine.\
               """

      refute text =~ "Filesystem"
      refute text =~ "secret"
      refute text =~ "staging"
    end

    test "shows the last `last` items" do
      entries = for i <- 1..10, do: user("message #{i}")
      text = read(entry(thread("c_1", "T"), :idle), entries, 3)
      assert text =~ "[user] message 8\n[user] message 9\n[user] message 10"
      refute text =~ "message 7"
    end

    test "cuts an item over 1,500 characters in the middle" do
      long = String.duplicate("a", 1_000) <> String.duplicate("b", 1_000)
      text = read(entry(thread("c_1", "T"), :idle), [answer(long)])
      [_header, item] = String.split(text, "\n\n", parts: 2)

      assert item =~ ~r/\A\[thread\] a+\n\[\.\.\.\d+ characters left out\.\.\.\]\nb+\z/
      assert String.length(item) < 1_600
    end

    test "cuts the items to 12,000 characters from the end, saying how many were left out" do
      entries = for i <- 1..20, do: user("#{i} " <> String.duplicate("x", 1_000))
      text = read(entry(thread("c_1", "T"), :idle), entries)
      [_header, items] = String.split(text, "\n\n", parts: 2)

      assert "...9 earlier items left out." <> rest = items
      assert String.length(rest) <= 12_001
      assert rest =~ "[user] 10 x"
      refute rest =~ "[user] 9 x"
      assert String.ends_with?(rest, "[user] 20 " <> String.duplicate("x", 1_000))
    end
  end

  test "what Blip's file tools say after a write or an edit" do
    assert Readout.file_written("notes.md", "garden", String.duplicate("x", 1_234), true) ==
             "Created notes.md in garden (1,234 characters)."

    assert Readout.file_written("notes.md", "garden", "é", false) ==
             "Wrote notes.md in garden (1 character)."

    assert Readout.file_edited("notes.md", "garden") == "Edited notes.md in garden."
  end

  test "the words for a project or thread that isn't there" do
    assert Readout.unknown_project("gardn", ["garden", "house"]) ==
             "There's no project called gardn. Projects: garden, house."

    assert Readout.unknown_project("gardn", []) ==
             "There's no project called gardn. There are no projects yet."

    assert Readout.unknown_thread("c_999") == "There's no thread c_999. list_threads shows them."
  end
end
