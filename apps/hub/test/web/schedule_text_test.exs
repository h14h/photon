defmodule PhotonWeb.ScheduleTextTest do
  @moduledoc "The pages' words for how often a schedule repeats, its last run and its state."

  use Photon.Case, async: true

  alias Photon.Schedules.Schedule
  alias PhotonWeb.ScheduleText

  test "every/1 names the largest whole unit, or counts minutes" do
    assert ScheduleText.every(5) == "every 5 minutes"
    assert ScheduleText.every(1) == "every minute"
    assert ScheduleText.every(60) == "every hour"
    assert ScheduleText.every(90) == "every 90 minutes"
    assert ScheduleText.every(120) == "every 2 hours"
    assert ScheduleText.every(1440) == "every day"
    assert ScheduleText.every(2160) == "every 36 hours"
    assert ScheduleText.every(4320) == "every 3 days"
    assert ScheduleText.every(10_080) == "every week"
    assert ScheduleText.every(20_160) == "every 2 weeks"
  end

  test "outcome/1 says what each firing did" do
    assert ScheduleText.outcome("started") == "started"
    assert ScheduleText.outcome("sent") == "sent"
    assert ScheduleText.outcome("queued") == "queued behind a run"
    assert ScheduleText.outcome("skipped_consent") == "skipped: scheduled work is off"

    assert ScheduleText.outcome("skipped_running") ==
             "skipped: the last thread was still running"

    assert ScheduleText.outcome("skipped_queued") ==
             "skipped: the last prompt was still waiting"

    assert ScheduleText.outcome("skipped_missing") == "skipped: the thread is gone"
    assert ScheduleText.outcome("failed") == "stopped after an error"
    assert ScheduleText.outcome("something_new") == "ran"
  end

  test "state/2 gives the when line's words, for the page to follow with the next time" do
    assert ScheduleText.state(:waiting, 1440) == {:next, "Every day · next"}
    assert ScheduleText.state(:waiting, 90) == {:next, "Every 90 minutes · next"}
    assert ScheduleText.state(:waiting, nil) == {:next, "Once ·"}
    assert ScheduleText.state(:done, nil) == {:done, "Done"}
  end

  test "state/2 says how to start a stopped schedule again" do
    assert ScheduleText.state({:stopped, "the database was busy"}, 60) ==
             {:stopped,
              "Stopped after an error: the database was busy. Save it to start it again."}

    assert ScheduleText.state({:stopped, "it failed."}, nil) ==
             {:stopped, "Stopped after an error: it failed. Pick a time and save it to run it."}
  end

  test "target/2 says where firings go, with the title to link" do
    assert ScheduleText.target(%Schedule{conversation_id: nil}, nil) ==
             {"Starts a new thread each time", nil}

    assert ScheduleText.target(%Schedule{conversation_id: "th_1"}, "Fix the pump") ==
             {"Wakes", ~s("Fix the pump")}

    assert ScheduleText.target(%Schedule{conversation_id: "th_1"}, nil) ==
             {"Wakes a thread that's gone", nil}
  end

  test "last/1 says what a last run links to" do
    assert ScheduleText.last("started") == {"started", :thread}
    assert ScheduleText.last("skipped_consent") == {"skipped: scheduled work is off", :settings}

    assert ScheduleText.last("skipped_running") ==
             {"skipped: the last thread was still running", nil}

    assert ScheduleText.last("sent") == {"sent", nil}
  end

  test "ran/2 says what Run now did" do
    assert ScheduleText.ran("started", nil) == "Started a thread."
    assert ScheduleText.ran("sent", "Fix the pump") == ~s(Sent to "Fix the pump".)

    assert ScheduleText.ran("queued", "Fix the pump") ==
             ~s(Queued for "Fix the pump", behind its run.)

    assert ScheduleText.ran("sent", nil) == "Sent to the thread."

    assert ScheduleText.ran("skipped_running", nil) ==
             "Skipped: the last thread was still running."

    assert ScheduleText.ran("something_new", nil) == "Ran it."
  end
end
