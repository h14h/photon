defmodule PhotonWeb.ThreadTextTest do
  @moduledoc "The pages' words for threads' states, the home page's summary and its lists."

  use Photon.Case, async: true

  alias PhotonWeb.ThreadText

  test "state/1 gives a state's label, from a board entry or the bare state" do
    assert ThreadText.state(:waiting) == "Waiting on you"
    assert ThreadText.state(:asking) == "Asking Blip"
    assert ThreadText.state(:running) == "Running"
    assert ThreadText.state(:failed) == "Failed"
    assert ThreadText.state(:unread) == "Finished"
    assert ThreadText.state(:quiet) == "Quiet"
    assert ThreadText.state(:idle) == "Idle"

    assert ThreadText.state(%{state: :idle, thread: %{last_run_status: "done"}}) == "Done"

    assert ThreadText.state(%{state: :idle, thread: %{resolved_at: ~U[2026-10-01 00:00:00Z]}}) ==
             "Resolved"
  end

  test "summary/1 counts what needs the owner" do
    assert ThreadText.summary(0) == "Nothing needs you right now."
    assert ThreadText.summary(1) == "1 thing needs you."
    assert ThreadText.summary(3) == "3 things need you."
  end

  test "more/1 is the line under a cut list" do
    assert ThreadText.more(4) == "and 4 more"
    assert ThreadText.more(1) == "and 1 more"
  end

  test "marked_read/1 says what Mark all read did" do
    assert ThreadText.marked_read(0) == "Nothing to mark read."
    assert ThreadText.marked_read(1) == "Marked 1 thread read."
    assert ThreadText.marked_read(4) == "Marked 4 threads read."
  end

  test "quiet/1 says how a quiet thread was left" do
    assert ThreadText.quiet(%{last_run_status: "stopped"}) == "Stopped"
    assert ThreadText.quiet(%{last_run_status: nil}) == "Idle"
  end

  test "one_line/1 puts text on one line" do
    assert ThreadText.one_line("Which  zone\nfirst?\n\n  Or both?") ==
             "Which zone first? Or both?"

    assert ThreadText.one_line(nil) == ""
  end
end
