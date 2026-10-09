defmodule Photon.Threads.StateTest do
  @moduledoc "A thread's state from its facts, and the run-end facts."

  use Photon.Case, async: true

  alias Photon.Threads.State

  @now ~U[2026-10-09 12:00:00.000000Z]
  @opts %{quiet_after: 72 * 3600}

  defp ago(hours), do: DateTime.add(@now, -hours * 3600, :second)

  # A thread idle for an hour, whose last run hasn't ended.
  defp facts(overrides) do
    Map.merge(
      %{
        busy?: false,
        question: nil,
        last_run_status: nil,
        last_run_ended_at: nil,
        last_run_asked: false,
        active_at: ago(1),
        seen_at: nil,
        resolved_at: nil
      },
      Map.new(overrides)
    )
  end

  defp state(overrides), do: State.of(facts(overrides), @now, @opts)

  describe "of/3, rule by rule" do
    test "1: a question with the owner is waiting, even while running" do
      assert state(question: :with_owner) == :waiting
      assert state(question: :with_owner, busy?: true) == :waiting
      assert state(question: :with_owner, resolved_at: ago(1)) == :waiting
    end

    test "2: running with a question Blip holds is asking" do
      assert state(busy?: true, question: :with_blip) == :asking
    end

    test "3: running is running, whatever the last run did" do
      assert state(busy?: true) == :running
      assert state(busy?: true, last_run_status: "failed", last_run_ended_at: ago(2)) == :running
      assert state(busy?: true, resolved_at: ago(1)) == :running
    end

    test "4: a resolved thread is idle, even when it failed" do
      assert state(resolved_at: ago(1), last_run_status: "failed", last_run_ended_at: ago(2)) ==
               :idle

      assert state(
               resolved_at: ago(1),
               last_run_status: "done",
               last_run_asked: true,
               last_run_ended_at: ago(2)
             ) == :idle
    end

    test "5: a failed run is failed, however old" do
      assert state(last_run_status: "failed", last_run_ended_at: ago(1)) == :failed

      assert state(last_run_status: "failed", last_run_ended_at: ago(500), active_at: ago(500)) ==
               :failed
    end

    test "6: a finished run that asked is waiting, seen or not" do
      assert state(last_run_status: "done", last_run_asked: true, last_run_ended_at: ago(1)) ==
               :waiting

      assert state(
               last_run_status: "done",
               last_run_asked: true,
               last_run_ended_at: ago(500),
               seen_at: ago(499)
             ) == :waiting
    end

    test "7: a finished run not seen since it ended is unread" do
      assert state(last_run_status: "done", last_run_ended_at: ago(1)) == :unread

      assert state(last_run_status: "done", last_run_ended_at: ago(1), seen_at: ago(2)) ==
               :unread

      assert state(
               last_run_status: "done",
               last_run_ended_at: ago(500),
               active_at: ago(500)
             ) == :unread
    end

    test "8: a stopped run left alone past the threshold is quiet" do
      assert state(last_run_status: "stopped", last_run_ended_at: ago(73), active_at: ago(80)) ==
               :quiet

      assert state(last_run_status: nil, active_at: ago(73)) == :quiet
    end

    test "8: the later of the last message and the run's end counts" do
      assert state(last_run_status: "stopped", last_run_ended_at: ago(80), active_at: ago(2)) ==
               :idle
    end

    test "9: otherwise idle" do
      assert state(last_run_status: "stopped", last_run_ended_at: ago(2), active_at: ago(3)) ==
               :idle

      assert state([]) == :idle
    end

    test "done, seen and old is idle, never quiet" do
      assert state(
               last_run_status: "done",
               last_run_ended_at: ago(500),
               seen_at: ago(499),
               active_at: ago(500)
             ) == :idle
    end

    test "stopped is never failed" do
      refute state(last_run_status: "stopped", last_run_ended_at: ago(1)) == :failed
      refute state(last_run_status: "stopped", last_run_ended_at: ago(100)) == :failed
    end
  end

  describe "label/2" do
    test "gives each state's words" do
      assert State.label(:waiting, facts([])) == "Waiting on you"
      assert State.label(:asking, facts([])) == "Asking Blip"
      assert State.label(:running, facts([])) == "Running"
      assert State.label(:failed, facts([])) == "Failed"
      assert State.label(:unread, facts([])) == "Finished"
      assert State.label(:quiet, facts([])) == "Quiet"
    end

    test "names an idle thread by why it is idle" do
      assert State.label(:idle, facts(resolved_at: ago(1), last_run_status: "done")) ==
               "Resolved"

      assert State.label(:idle, facts(last_run_status: "done")) == "Done"
      assert State.label(:idle, facts(last_run_status: "stopped")) == "Idle"
      assert State.label(:idle, facts([])) == "Idle"
    end
  end

  describe "unseen?/1" do
    test "is a finished run the owner hasn't looked at since it ended" do
      assert State.unseen?(facts(last_run_status: "done", last_run_ended_at: ago(1)))

      assert State.unseen?(
               facts(last_run_status: "done", last_run_ended_at: ago(1), seen_at: ago(2))
             )

      refute State.unseen?(
               facts(last_run_status: "done", last_run_ended_at: ago(2), seen_at: ago(1))
             )

      refute State.unseen?(facts(last_run_status: "failed", last_run_ended_at: ago(1)))
      refute State.unseen?(facts([]))
      refute State.unseen?(%{})
    end
  end

  describe "asks?/1" do
    test "a plain question at the end" do
      assert State.asks?("I checked zone 2.\n\nShould I water it now?")
    end

    test "a question in bold, in italics or in quotes" do
      assert State.asks?("Done with the pump.\n\n**Should I order a new valve?**")
      assert State.asks?("_Want me to go on?_  ")
      assert State.asks?(~s(The last line: "Shall I restart it?"))
      assert State.asks?("Which one (`a` or `b`)?")
    end

    test "a question followed by a code block" do
      assert State.asks?("Run this?\n\n```sh\nsudo systemctl restart pump\n```\n")
      assert State.asks?("Run this?\n```sh\nls\n```")
    end

    test "a question in the middle with a statement after" do
      refute State.asks?("Should I water it?\n\nNo: it rained, so I left it.")
      refute State.asks?("Is it wet? It is. I left it.")
    end

    test "no question" do
      refute State.asks?("Watered zone 2.")
      refute State.asks?("Here is the fix:\n\n```\nwhy?\n```\n\nDone.")
    end

    test "empty text, nil and other terms" do
      refute State.asks?("")
      refute State.asks?("  \n\n ")
      refute State.asks?("```\nok?\n```")
      refute State.asks?(nil)
      refute State.asks?(5)
    end
  end

  describe "note/2" do
    test "done is the answer's first paragraph" do
      assert State.note("done", "Watered   zone 2\nfor ten minutes.\n\nAll good.") ==
               "Watered zone 2 for ten minutes."
    end

    test "done and asking is its last paragraph" do
      assert State.note("done", "Zone 2 is dry.\n\nShould I water it?") == "Should I water it?"

      assert State.note("done", "Zone 2 is dry.\n\nRun this?\n\n```sh\nwater 2\n```") ==
               "Run this?"
    end

    test "failed is the reason" do
      assert State.note("failed", "HTTP 500:  the pump\nis unplugged") ==
               "HTTP 500: the pump is unplugged"
    end

    test "stopped has none" do
      assert State.note("stopped", "stopped") == nil
    end

    test "cuts at 280 characters at a word boundary" do
      text = String.duplicate("water the beds ", 40)
      note = State.note("done", text)
      assert String.length(note) <= 280
      assert String.ends_with?(note, "...")

      # Whole words: what comes before the "..." is followed by a space.
      kept = String.trim_trailing(note, "...")
      assert String.starts_with?(text, kept <> " ")

      short = String.duplicate("a", 280)
      assert State.note("done", short) == short
      assert String.length(State.note("failed", String.duplicate("b", 400))) == 280
    end

    test "nil and empty text, and other terms, give nil" do
      assert State.note("done", nil) == nil
      assert State.note("done", "") == nil
      assert State.note("done", "```\ncode\n```") == nil
      assert State.note("failed", nil) == nil
      assert State.note("failed", %{"oops" => 1}) == nil
      assert State.note(nil, "text") == nil
    end
  end

  describe "last_activity/1" do
    test "is the later of the last message and the last run's end" do
      assert State.last_activity(%{active_at: ago(5), last_run_ended_at: ago(2)}) == ago(2)
      assert State.last_activity(%{active_at: ago(1), last_run_ended_at: ago(2)}) == ago(1)
      assert State.last_activity(%{active_at: ago(3), last_run_ended_at: nil}) == ago(3)
      assert State.last_activity(%{}) == nil
    end
  end

  describe "sections/1" do
    # A board entry: thread `id` in `state`, with its row's facts and
    # open questions.
    defp board_entry(id, state, thread \\ [], questions \\ []) do
      %{
        id: id,
        state: state,
        thread:
          Map.merge(
            %{id: id, active_at: ago(1), last_run_ended_at: nil, last_run_status: nil},
            Map.new(thread)
          ),
        project: %{id: "p_1", slug: "garden", name: "Garden"},
        questions: questions
      }
    end

    defp open_question(id, status, at, overrides \\ []) do
      Map.merge(
        %{id: id, status: status, inserted_at: at, passed_at: nil},
        Map.new(overrides)
      )
    end

    defp ids(rows), do: Enum.map(rows, & &1.thread.id)

    test "puts each state in its section, and idle threads in none" do
      board = [
        board_entry("c_run", :running),
        board_entry("c_ask", :asking, [], [open_question("q_1", "asked", ago(1))]),
        board_entry("c_wait", :waiting, last_run_status: "done", last_run_ended_at: ago(2)),
        board_entry("c_fail", :failed, last_run_status: "failed", last_run_ended_at: ago(3)),
        board_entry("c_unread", :unread, last_run_status: "done", last_run_ended_at: ago(4)),
        board_entry("c_quiet", :quiet, last_run_status: "stopped", last_run_ended_at: ago(100)),
        board_entry("c_idle", :idle, last_run_status: "done", last_run_ended_at: ago(100))
      ]

      sections = State.sections(board)

      assert [%{kind: :thread, id: "c_wait"}] = sections.waiting
      assert ids(sections.failed.rows) == ["c_fail"]
      assert ids(sections.unread.rows) == ["c_unread"]
      assert ids(sections.running) == ["c_run", "c_ask"]
      assert ids(sections.quiet.rows) == ["c_quiet"]
      assert sections.needs_you == 3

      refute "c_idle" in (ids(sections.running) ++ ids(sections.quiet.rows))
    end

    test "nothing on the board is empty sections" do
      assert State.sections([]) == %{
               needs_you: 0,
               waiting: [],
               failed: %{rows: [], more: 0},
               unread: %{rows: [], more: 0},
               running: [],
               quiet: %{rows: [], more: 0}
             }
    end

    test "Waiting on you lists each question with the owner and asking threads, longest wait first" do
      two =
        board_entry("c_two", :waiting, [], [
          open_question("q_late", "with_owner", ago(9), passed_at: ago(1)),
          open_question("q_early", "with_owner", ago(9), passed_at: ago(6)),
          open_question("q_blip", "asked", ago(2))
        ])

      asked = board_entry("c_asked", :waiting, last_run_status: "done", last_run_ended_at: ago(3))

      sections = State.sections([two, asked])

      assert Enum.map(sections.waiting, &{&1.kind, &1.id}) == [
               {:question, "q_early"},
               {:thread, "c_asked"},
               {:question, "q_late"}
             ]

      assert hd(sections.waiting).entry.thread.id == "c_two"
      # Two questions from one thread are one thread that needs the owner.
      assert sections.needs_you == 2
    end

    test "a waiting thread with a question with the owner has no row of its own" do
      thread =
        board_entry("c_1", :waiting, [last_run_status: "done", last_run_ended_at: ago(5)], [
          open_question("q_1", "with_owner", ago(2), passed_at: ago(1))
        ])

      assert [%{kind: :question, id: "q_1"}] = State.sections([thread]).waiting
    end

    test "Failed and Finished are newest first" do
      board =
        for {id, hours} <- [{"c_old", 30}, {"c_new", 1}, {"c_mid", 5}],
            do: board_entry(id, :failed, last_run_status: "failed", last_run_ended_at: ago(hours))

      assert ids(State.sections(board).failed.rows) == ["c_new", "c_mid", "c_old"]

      unread = Enum.map(board, &%{&1 | state: :unread})
      assert ids(State.sections(unread).unread.rows) == ["c_new", "c_mid", "c_old"]
    end

    test "Running is the working threads, longest running first, then those asking Blip" do
      board = [
        board_entry("c_ask_new", :asking, [], [open_question("q_2", "asked", ago(1))]),
        board_entry("c_run_new", :running, active_at: ago(1)),
        board_entry("c_ask_old", :asking, [], [open_question("q_1", "asked", ago(5))]),
        board_entry("c_run_old", :running, active_at: ago(4))
      ]

      assert ids(State.sections(board).running) ==
               ["c_run_old", "c_run_new", "c_ask_old", "c_ask_new"]
    end

    test "Gone quiet is the oldest activity first" do
      board = [
        board_entry("c_a", :quiet, active_at: ago(80), last_run_ended_at: ago(75)),
        board_entry("c_b", :quiet, active_at: ago(200), last_run_ended_at: ago(190)),
        board_entry("c_c", :quiet, active_at: ago(100), last_run_ended_at: nil)
      ]

      assert ids(State.sections(board).quiet.rows) == ["c_b", "c_c", "c_a"]
    end

    test "cuts Failed and Finished at 20 and Gone quiet at 10, with how many more" do
      many = fn state, count ->
        for n <- 1..count,
            do:
              board_entry("c_#{state}_#{n}", state, last_run_ended_at: ago(n), active_at: ago(n))
      end

      sections = State.sections(many.(:failed, 24) ++ many.(:unread, 21) ++ many.(:quiet, 22))

      assert %{rows: failed, more: 4} = sections.failed
      assert length(failed) == 20
      assert hd(failed).thread.id == "c_failed_1"

      assert %{rows: unread, more: 1} = sections.unread
      assert length(unread) == 20

      assert %{rows: quiet, more: 12} = sections.quiet
      assert length(quiet) == 10
      assert hd(quiet).thread.id == "c_quiet_22"

      # The count is every thread, not just those shown.
      assert sections.needs_you == 45
    end

    test "Waiting on you and Running are never cut" do
      board =
        for n <- 1..30,
            do:
              board_entry("c_#{n}", :waiting, last_run_status: "done", last_run_ended_at: ago(n))

      assert length(State.sections(board).waiting) == 30

      running = for n <- 1..30, do: board_entry("c_r#{n}", :running)
      assert length(State.sections(running).running) == 30
    end
  end
end
