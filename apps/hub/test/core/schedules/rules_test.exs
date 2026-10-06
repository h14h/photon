defmodule Photon.Schedules.RulesTest do
  @moduledoc "The rules for schedules (sections 3.1 to 3.5 of the step 3 plan)."

  use Photon.Case, async: true

  alias Photon.Schedules.Rules

  @minute 60_000
  @day 1_440 * @minute
  # 2026-10-08 14:05:30 UTC
  @now DateTime.to_unix(~U[2026-10-08 14:05:30Z], :millisecond)
  @ctx %{now: @now, thread_ids: ["th_pump", "th_disks"]}

  defp params(overrides) do
    Map.merge(
      %{
        "prompt" => "Check the backups",
        "at" => "2026-10-08T18:00:00+02:00",
        "repeat" => "once",
        "every" => "1",
        "unit" => "days",
        "target" => "new_thread"
      },
      overrides
    )
  end

  defp errors(overrides) do
    {:error, errors} = Rules.schedule(params(overrides), @ctx)
    errors
  end

  defp every(every, unit) do
    Rules.schedule(params(%{"repeat" => "every", "every" => every, "unit" => unit}), @ctx)
  end

  describe "schedule/2" do
    test "reads a one-off for a new thread each time, in UTC" do
      assert Rules.schedule(params(%{}), @ctx) ==
               {:ok,
                %{
                  prompt: "Check the backups",
                  first_at: ~U[2026-10-08 16:00:00.000000Z],
                  every_minutes: nil,
                  conversation_id: nil
                }}
    end

    test "stores the time with microseconds, as the row's column wants" do
      {:ok, %{first_at: first_at}} = Rules.schedule(params(%{}), @ctx)
      assert first_at.microsecond == {0, 6}
    end

    test "takes atom keys too" do
      assert {:ok, %{prompt: "Check the backups"}} =
               Rules.schedule(
                 %{
                   prompt: "Check the backups",
                   at: "2026-10-09T09:00:00Z",
                   repeat: "once",
                   target: "new_thread"
                 },
                 @ctx
               )
    end

    test "trims the prompt and makes its line ends \\n" do
      assert {:ok, %{prompt: "one\ntwo"}} =
               Rules.schedule(params(%{"prompt" => "  one\r\ntwo \n"}), @ctx)
    end

    test "requires a prompt of at most 4,000 characters" do
      assert errors(%{"prompt" => " \n "}) == %{prompt: "Say what this schedule should ask for."}
      assert errors(%{"prompt" => nil}) == %{prompt: "Say what this schedule should ask for."}

      assert {:ok, _} = Rules.schedule(params(%{"prompt" => String.duplicate("a", 4_000)}), @ctx)

      assert errors(%{"prompt" => String.duplicate("a", 4_001)}) == %{
               prompt:
                 "Keep the prompt under 4,000 characters, and put the rest in a context file."
             }
    end

    test "requires a time with an offset" do
      for at <- [nil, "", "tomorrow", "2026-10-09T09:00:00", "2026-10-09"] do
        assert errors(%{"at" => at}) == %{at: "Pick a date and time."}, inspect(at)
      end
    end

    test "takes a one-off up to a minute ago, the form's current minute" do
      assert {:ok, %{first_at: ~U[2026-10-08 14:05:00.000000Z]}} =
               Rules.schedule(params(%{"at" => "2026-10-08T14:05:00Z"}), @ctx)

      assert {:ok, %{first_at: ~U[2026-10-08 14:04:30.000000Z]}} =
               Rules.schedule(params(%{"at" => "2026-10-08T14:04:30Z"}), @ctx)

      assert errors(%{"at" => "2026-10-08T14:04:29Z"}) == %{at: "That time has passed."}
    end

    test "takes a first time up to 10 years ahead" do
      assert {:ok, %{first_at: ~U[2036-10-01 09:00:00.000000Z]}} =
               Rules.schedule(params(%{"at" => "2036-10-01T09:00:00Z"}), @ctx)

      for repeat <- ["once", "every"] do
        assert errors(%{"at" => "2036-10-07T09:00:00Z", "repeat" => repeat}) ==
                 %{at: "Pick a time in the next 10 years."}
      end
    end

    test "takes a repeating schedule whose first time has passed" do
      assert {:ok, %{first_at: ~U[2026-10-01 09:00:00.000000Z], every_minutes: 1_440}} =
               Rules.schedule(
                 params(%{"at" => "2026-10-01T09:00:00Z", "repeat" => "every"}),
                 @ctx
               )
    end

    test "requires once or every" do
      assert errors(%{"repeat" => "sometimes"}) == %{repeat: "Pick Once or Every."}
      assert errors(%{"repeat" => nil}) == %{repeat: "Pick Once or Every."}
    end

    test "reads every number of minutes, hours, days or weeks" do
      assert {:ok, %{every_minutes: 5}} = every("5", "minutes")
      assert {:ok, %{every_minutes: 120}} = every("2", "hours")
      assert {:ok, %{every_minutes: 4_320}} = every(" 3 ", "days")
      assert {:ok, %{every_minutes: 10_080}} = every(1, "weeks")
    end

    test "ignores the interval of a one-off" do
      assert {:ok, %{every_minutes: nil}} =
               Rules.schedule(params(%{"every" => "x", "unit" => "fortnights"}), @ctx)
    end

    test "repeats no more often than every 5 minutes and at least once a year" do
      assert {:error, %{every: "Repeat no more often than every 5 minutes."}} =
               every("4", "minutes")

      assert {:error, %{every: "Repeat no more often than every 5 minutes."}} =
               every("0", "hours")

      assert {:ok, %{every_minutes: 524_160}} = every("52", "weeks")
      assert {:error, %{every: "Repeat at least once a year."}} = every("53", "weeks")
      assert {:error, %{every: "Repeat at least once a year."}} = every("365", "days")
    end

    test "refuses an interval that isn't a whole number of a known unit" do
      message = "Repeat every whole number of minutes, hours, days or weeks."

      for {every, unit} <- [{"1.5", "hours"}, {"", "days"}, {"two", "days"}, {"2", "fortnights"}] do
        assert every(every, unit) == {:error, %{every: message}}, inspect({every, unit})
      end
    end

    test "targets one of the project's threads, or a new thread each time" do
      assert {:ok, %{conversation_id: "th_pump"}} =
               Rules.schedule(params(%{"target" => "th_pump"}), @ctx)

      message = "Pick one of this project's threads, or a new thread each time."

      for target <- ["th_other", "", nil] do
        assert errors(%{"target" => target}) == %{target: message}, inspect(target)
      end
    end

    test "gives every field's error at once" do
      errors =
        errors(%{
          "prompt" => "",
          "at" => "",
          "repeat" => "every",
          "every" => "1",
          "unit" => "minutes",
          "target" => "th_other"
        })

      assert errors |> Map.keys() |> Enum.sort() == [:at, :every, :prompt, :target]
    end
  end

  describe "from_tool/2 (Blip's schedule tool)" do
    test "starts in some minutes, at a time, or one interval from now" do
      assert Rules.from_tool(%{"prompt" => "check disks", "in_minutes" => 10}, @now) ==
               {:ok,
                %{
                  prompt: "check disks",
                  first_at: ~U[2026-10-08 14:15:30.000000Z],
                  every_minutes: nil
                }}

      assert {:ok, %{first_at: ~U[2027-01-01 09:00:00.000000Z], every_minutes: 60}} =
               Rules.from_tool(
                 %{"prompt" => "ping", "at" => "2027-01-01T09:00:00Z", "every_minutes" => 60},
                 @now
               )

      assert {:ok, %{first_at: ~U[2026-10-08 14:10:30.000000Z], every_minutes: 5}} =
               Rules.from_tool(%{"prompt" => "p", "every_minutes" => 5}, @now)
    end

    test "in_minutes 0 is now, and an at up to a minute ago is taken" do
      assert {:ok, %{first_at: ~U[2026-10-08 14:05:30.000000Z]}} =
               Rules.from_tool(%{"prompt" => "p", "in_minutes" => 0}, @now)

      assert {:ok, %{first_at: ~U[2026-10-08 14:04:30.000000Z]}} =
               Rules.from_tool(%{"prompt" => "p", "at" => "2026-10-08T14:04:30Z"}, @now)
    end

    test "refuses a time in the past, a bad time, too short an interval, or no time" do
      assert Rules.from_tool(%{"prompt" => "p", "at" => "2000-01-01T00:00:00Z"}, @now) ==
               {:error, "2000-01-01T00:00:00Z is in the past."}

      assert Rules.from_tool(%{"prompt" => "p", "at" => "2026-10-08T14:04:29Z"}, @now) ==
               {:error, "2026-10-08T14:04:29Z is in the past."}

      assert Rules.from_tool(%{"prompt" => "p", "at" => "tomorrow"}, @now) ==
               {:error, "at must be ISO 8601 with a UTC offset, like 2026-10-04T09:00:00-05:00."}

      assert Rules.from_tool(%{"prompt" => "p", "in_minutes" => 1, "every_minutes" => 1}, @now) ==
               {:error, "every_minutes must be at least 5."}

      assert Rules.from_tool(%{"prompt" => "p"}, @now) == {:error, "Give in_minutes or at."}
    end

    test "keeps the form's bounds, so every time it reaches is a date the row holds" do
      assert Rules.from_tool(%{"prompt" => "p", "in_minutes" => 10_000_000_000}, @now) ==
               {:error, "in_minutes must be at most 5256000 (10 years)."}

      assert {:ok, %{first_at: ~U[2036-10-05 14:05:30.000000Z]}} =
               Rules.from_tool(%{"prompt" => "p", "in_minutes" => 5_256_000}, @now)

      assert Rules.from_tool(%{"prompt" => "p", "at" => "9999-12-31T00:00:00Z"}, @now) ==
               {:error, "9999-12-31T00:00:00Z is more than 10 years away."}

      for args <- [
            %{"prompt" => "p", "every_minutes" => 4_300_000_000},
            %{"prompt" => "p", "in_minutes" => 0, "every_minutes" => 4_300_000_000},
            %{"prompt" => "p", "in_minutes" => 0, "every_minutes" => 524_161}
          ] do
        assert Rules.from_tool(args, @now) ==
                 {:error, "every_minutes must be at most 524160 (52 weeks)."}
      end

      assert {:ok, %{every_minutes: 524_160}} =
               Rules.from_tool(%{"prompt" => "p", "every_minutes" => 524_160}, @now)
    end

    test "requires a prompt the row can hold" do
      assert Rules.from_tool(%{"in_minutes" => 1}, @now) ==
               {:error, "Say what this schedule should ask for."}

      assert {:error, "Keep the prompt under 4,000 characters" <> _} =
               Rules.from_tool(
                 %{"prompt" => String.duplicate("a", 4_001), "in_minutes" => 1},
                 @now
               )
    end
  end

  describe "arm/4" do
    test "a one-off arms at its time, up to a minute ago" do
      assert Rules.arm(@now, nil, @now, nil) == @now
      assert Rules.arm(@now - 30_000, nil, @now, nil) == @now - 30_000
      assert Rules.arm(@now - 60_000, nil, @now, nil) == @now - 60_000
      assert Rules.arm(@now + @day, nil, @now, nil) == @now + @day
    end

    test "a one-off more than a minute ago is finished" do
      assert Rules.arm(@now - 61_000, nil, @now, nil) == :finished
    end

    test "a one-off that already fired at its time is finished, even inside the minute" do
      # Fired at 14:05:00, edited at 14:05:30 keeping the time.
      fired = @now - 30_000
      assert Rules.arm(fired, nil, @now, fired) == :finished
    end

    test "a repeating one made a one-off at the slot it just fired is finished" do
      # Every 5 minutes, fired at 14:05:00, edited at 14:05:30 to Once at 14:05.
      fired = @now - 30_000
      input = %{"first_at" => fired, "every_ms" => 5 * @minute}
      checkpoint = %{"next_at" => fired + 5 * @minute, "runs" => 1}

      assert Rules.fired_through(input, checkpoint, "waiting") == fired
      assert Rules.arm(fired, nil, @now, fired) == :finished
    end

    test "a one-off moved to a later time after it fired arms at the new time" do
      assert Rules.arm(@now + @minute, nil, @now, @now - 30_000) == @now + @minute
    end

    test "a repeating one whose first time was 30 seconds ago arms at it" do
      first_at = @now - 30_000
      assert Rules.arm(first_at, 5 * @minute, @now, nil) == first_at
    end

    test "a repeating one that fired on that slot arms at the next slot" do
      first_at = @now - 30_000
      assert Rules.arm(first_at, 5 * @minute, @now, first_at) == first_at + 5 * @minute
    end

    test "a repeating one whose first time was a day ago arms at the first slot at or after a minute ago" do
      every = 7 * @minute
      first_at = @now - @day
      armed = Rules.arm(first_at, every, @now, nil)

      assert armed >= @now - @minute
      assert armed - every < @now - @minute
      assert rem(armed - first_at, every) == 0
    end

    test "a slot exactly a minute ago still fires" do
      first_at = @now - @minute - 10 * @minute
      assert Rules.arm(first_at, 5 * @minute, @now, nil) == @now - @minute
    end

    test "a repeating one never fires a slot the old task fired" do
      every = 5 * @minute
      first_at = @now - 10 * @minute
      # The old task fired the slot 5 minutes ago; the one due now is next.
      assert Rules.arm(first_at, every, @now, @now - 5 * @minute) == @now
      # It fired the one due now too.
      assert Rules.arm(first_at, every, @now, @now) == @now + every
      # The old task fired the slot 30 seconds ago.
      assert Rules.arm(@now - 30_000 - every, every, @now, @now - 30_000) == @now - 30_000 + every
    end
  end

  describe "fired_through/3" do
    test "is nil for a task that hasn't fired" do
      assert Rules.fired_through(%{"first_at" => 1_000, "every_ms" => nil}, %{}, "waiting") == nil

      assert Rules.fired_through(
               %{"first_at" => 1_000, "every_ms" => 100},
               %{"next_at" => 1_000, "runs" => 0},
               "waiting"
             ) == nil

      assert Rules.fired_through(
               %{"first_at" => 1_000, "every_ms" => 100},
               %{"next_at" => 1_000},
               "running"
             ) == nil
    end

    test "is the first time of a one-off that finished done" do
      assert Rules.fired_through(
               %{"first_at" => 1_000, "every_ms" => nil},
               %{"next_at" => 1_000, "runs" => 0},
               "done"
             ) == 1_000
    end

    test "is nil for a one-off that ended without firing" do
      for status <- ["aborted", "failed", "running", "waiting"] do
        assert Rules.fired_through(
                 %{"first_at" => 1_000, "every_ms" => nil},
                 %{"next_at" => 1_000, "runs" => 0},
                 status
               ) == nil
      end
    end

    test "is the slot before the next one for a repeating task that has fired" do
      input = %{"first_at" => 1_000, "every_ms" => 100}
      assert Rules.fired_through(input, %{"next_at" => 1_100, "runs" => 1}, "waiting") == 1_000
    end

    test "counts the slots missed while the hub was down as fired" do
      input = %{"first_at" => 1_000, "every_ms" => 100}
      # Fired 1_000, then 1_100 late at 1_350, which skipped 1_200 and 1_300.
      next_at = Rules.next_after(1_100, 100, 1_350)
      assert Rules.fired_through(input, %{"next_at" => next_at, "runs" => 2}, "waiting") == 1_300
    end

    test "with arm/4, an edit neither skips nor repeats a firing" do
      input = %{"first_at" => 1_000, "every_ms" => 100}
      checkpoint = %{"next_at" => 1_100, "runs" => 1}
      fired = Rules.fired_through(input, checkpoint, "waiting")

      # Edited in the second the 1_100 slot was due, before it fired.
      assert Rules.arm(1_000, 100, 1_100, fired) == 1_100
      # Edited after it fired: the next slot.
      fired = Rules.fired_through(input, %{"next_at" => 1_200, "runs" => 2}, "waiting")
      assert Rules.arm(1_000, 100, 1_150, fired) == 1_200
    end
  end

  describe "next_after/3" do
    test "is the next time on the grid after now, skipping missed slots" do
      assert Rules.next_after(1_000, 100, 1_050) == 1_100
      assert Rules.next_after(1_000, 100, 1_350) == 1_400
      assert Rules.next_after(1_000, 100, 1_400) == 1_500
      assert Rules.next_after(1_000, 100, 500) == 1_100
    end
  end

  describe "every_unit/1" do
    test "says an interval in the largest unit that divides it" do
      assert Rules.every_unit(5) == {5, "minutes"}
      assert Rules.every_unit(90) == {90, "minutes"}
      assert Rules.every_unit(60) == {1, "hours"}
      assert Rules.every_unit(2160) == {36, "hours"}
      assert Rules.every_unit(1440) == {1, "days"}
      assert Rules.every_unit(4320) == {3, "days"}
      assert Rules.every_unit(20_160) == {2, "weeks"}
    end

    test "reads back through schedule/2 to the same minutes" do
      now = DateTime.to_unix(~U[2026-10-08 14:00:00Z], :millisecond)

      for minutes <- [5, 90, 60, 2160, 1440, 20_160] do
        {every, unit} = Rules.every_unit(minutes)

        params = %{
          "prompt" => "Check",
          "at" => "2026-10-08T15:00:00Z",
          "repeat" => "every",
          "every" => Integer.to_string(every),
          "unit" => unit,
          "target" => "new_thread"
        }

        assert {:ok, %{every_minutes: ^minutes}} =
                 Rules.schedule(params, %{now: now, thread_ids: []})
      end
    end
  end

  describe "next_hour/1" do
    test "is the first whole hour after now" do
      at = &DateTime.to_unix(&1, :millisecond)
      assert Rules.next_hour(at.(~U[2026-10-08 14:05:40Z])) == at.(~U[2026-10-08 15:00:00Z])
      assert Rules.next_hour(at.(~U[2026-10-08 14:00:00Z])) == at.(~U[2026-10-08 15:00:00Z])
      assert Rules.next_hour(at.(~U[2026-10-08 23:59:59Z])) == at.(~U[2026-10-09 00:00:00Z])
    end
  end

  describe "target/1" do
    test "follows from the project and the conversation" do
      assert Rules.target(%{project_id: nil, conversation_id: "c_blip"}) == :blip
      assert Rules.target(%{project_id: "p_1", conversation_id: nil}) == :new_thread
      assert Rules.target(%{project_id: "p_1", conversation_id: "th_pump"}) == :thread
    end
  end

  describe "fire/2" do
    @allowed %{allowed?: true}

    test "skips without consent, with a notice where there is a conversation" do
      assert Rules.fire(:blip, %{allowed?: false}) == {:skip, "skipped_consent", :notice}

      assert Rules.fire(:thread, %{allowed?: false, thread?: true}) ==
               {:skip, "skipped_consent", :notice}

      assert Rules.fire(:new_thread, %{allowed?: false, last_thread_running?: false}) ==
               {:skip, "skipped_consent", :quiet}

      assert Rules.fire(:blip, %{}) == {:skip, "skipped_consent", :notice}
    end

    test "a new-thread schedule skips while its last thread is still running" do
      assert Rules.fire(:new_thread, %{allowed?: true, last_thread_running?: true}) ==
               {:skip, "skipped_running", :quiet}
    end

    test "a prompt doesn't queue behind one of its own" do
      assert Rules.fire(:blip, %{allowed?: true, queued?: true, busy?: true}) ==
               {:skip, "skipped_queued", :quiet}

      assert Rules.fire(:thread, %{allowed?: true, thread?: true, queued?: true, busy?: true}) ==
               {:skip, "skipped_queued", :quiet}
    end

    test "a thread that is gone is skipped, before consent, since it can't take a notice" do
      assert Rules.fire(:thread, %{allowed?: true, thread?: false}) ==
               {:skip, "skipped_missing", :quiet}

      assert Rules.fire(:thread, %{allowed?: false}) == {:skip, "skipped_missing", :quiet}
    end

    test "a new-thread schedule starts a thread, also on its first firing" do
      assert Rules.fire(:new_thread, Map.put(@allowed, :last_thread_running?, false)) ==
               {:start, "started"}

      assert Rules.fire(:new_thread, @allowed) == {:start, "started"}
    end

    test "Blip or a thread, idle, gets the prompt and starts a run" do
      assert Rules.fire(:blip, %{allowed?: true, queued?: false, busy?: false}) ==
               {:submit, "sent"}

      assert Rules.fire(:thread, %{allowed?: true, thread?: true, queued?: false, busy?: false}) ==
               {:submit, "sent"}
    end

    test "Blip or a thread, busy, gets the prompt queued behind the current run" do
      assert Rules.fire(:blip, %{allowed?: true, queued?: false, busy?: true}) ==
               {:submit, "queued"}

      assert Rules.fire(:thread, %{allowed?: true, thread?: true, busy?: true}) ==
               {:submit, "queued"}
    end
  end

  describe "what a firing writes" do
    test "text/1 marks the prompt as scheduled" do
      assert Rules.text("check disks") == "[Scheduled] check disks"
    end

    test "skipped_note/2 says why, in Blip's words or a thread's" do
      assert Rules.skipped_note(:blip, "check disks") == %{
               "message" =>
                 ~s{Skipped "check disks": scheduled work is off. Turn it on in Settings to let me use your plan while you're away.},
               "notice" => true
             }

      assert Rules.skipped_note(:thread, "check disks") == %{
               "message" =>
                 ~s{Skipped the scheduled prompt "check disks": scheduled work is off. Turn it on in Settings to let schedules use your ChatGPT plan while you're away.},
               "notice" => true
             }
    end

    test "request_id/3 is one per schedule, task and firing" do
      assert Rules.request_id("sc_1", "t_r", 2) == "schedule:sc_1:t_r:2"
    end

    test "when_text/2 says when, as Blip's tool does" do
      assert Rules.when_text(~U[2026-10-08 09:00:00.000000Z], 1_440) ==
               "first at 2026-10-08 09:00 UTC, then every 1440 minutes"

      assert Rules.when_text(~U[2026-10-08 09:00:00.000000Z], nil) ==
               "first at 2026-10-08 09:00 UTC"
    end

    test "datetime/1 turns milliseconds into the row's time" do
      assert Rules.datetime(@now) == ~U[2026-10-08 14:05:30.000000Z]
    end
  end
end
