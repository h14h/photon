defmodule Photon.Threads.StateTest do
  @moduledoc "A thread's state from its facts, and the run-end facts (section 2.2)."

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
end
