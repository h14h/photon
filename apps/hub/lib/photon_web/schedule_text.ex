defmodule PhotonWeb.ScheduleText do
  @moduledoc """
  The words the pages use for schedules: how often one repeats ("every
  day"), what its last firing did ("skipped: scheduled work is off"), its
  when line for each state ("Every day · next", "Done", "Stopped after
  an error: ..."), where it goes ("Starts a new thread each time", "Wakes
  "Fix the pump""), and what Run now did ("Started a thread.").

  Pure: times are never formatted here. The browser knows the owner's time
  zone, so a page renders each time with `PhotonWeb.TimeComponents.local_time/1`
  next to these words.
  """

  alias Photon.Schedules
  alias Photon.Schedules.Schedule

  @hour 60
  @day 24 * @hour
  @week 7 * @day

  @doc ~S"""
  How often a schedule repeats, from its `every_minutes`: "every 5
  minutes", "every hour", "every 2 hours", "every day", "every 3 days",
  "every week". The largest of weeks, days and hours that divides the
  interval names it; anything else is said in minutes ("every 90
  minutes").
  """
  @spec every(pos_integer()) :: String.t()
  def every(minutes) when is_integer(minutes) and minutes > 0 do
    cond do
      rem(minutes, @week) == 0 -> "every " <> count(div(minutes, @week), "week")
      rem(minutes, @day) == 0 -> "every " <> count(div(minutes, @day), "day")
      rem(minutes, @hour) == 0 -> "every " <> count(div(minutes, @hour), "hour")
      true -> "every " <> count(minutes, "minute")
    end
  end

  @doc ~S"""
  What a firing did, from the row's `last_outcome` (section 3.5 of the
  step 3 plan): "started", "sent", "queued behind a run", a "skipped: ..."
  reason, or "stopped after an error". An outcome this version doesn't
  know reads as "ran".
  """
  @spec outcome(Schedule.outcome()) :: String.t()
  def outcome("started"), do: "started"
  def outcome("sent"), do: "sent"
  def outcome("queued"), do: "queued behind a run"
  def outcome("skipped_consent"), do: "skipped: scheduled work is off"
  def outcome("skipped_running"), do: "skipped: the last thread was still running"
  def outcome("skipped_queued"), do: "skipped: the last prompt was still waiting"
  def outcome("skipped_missing"), do: "skipped: the thread is gone"
  def outcome("failed"), do: "stopped after an error"
  def outcome(_unknown), do: "ran"

  @doc ~S"""
  A schedule's when line for its `state` (`Photon.Schedules.list/1`),
  tagged with what goes with it:

    * `{:next, words}` while it waits: "Every day · next" or "Once ·",
      for the page to follow with the next time
    * `{:done, "Done"}` for a one-off that fired
    * `{:stopped, words}` when its task failed, said in the error colour:
      "Stopped after an error: <reason>. Save it to start it again." for a
      repeating schedule, or "... Pick a time and save it to run it." for
      a one-off, whose time has passed
  """
  @spec state(Schedules.state(), pos_integer() | nil) ::
          {:next | :done | :stopped, String.t()}
  def state(:waiting, nil), do: {:next, "Once ·"}
  def state(:waiting, every_minutes), do: {:next, capitalize(every(every_minutes)) <> " · next"}
  def state(:done, _every_minutes), do: {:done, "Done"}

  def state({:stopped, reason}, nil),
    do: {:stopped, stopped(reason) <> " Pick a time and save it to run it."}

  def state({:stopped, reason}, _every_minutes),
    do: {:stopped, stopped(reason) <> " Save it to start it again."}

  defp stopped(reason), do: "Stopped after an error: #{String.trim_trailing(reason, ".")}."

  @doc ~S"""
  Where a schedule's firings go, for its row: `{words, nil}` for a new
  thread each time ("Starts a new thread each time"), or `{"Wakes",
  ~s("Fix the pump")}` for one thread, whose quoted title the page links
  to the thread. A thread that is gone reads `{"Wakes a thread that's
  gone", nil}`.
  """
  @spec target(Schedule.t(), String.t() | nil) :: {String.t(), String.t() | nil}
  def target(%Schedule{conversation_id: nil}, _title), do: {"Starts a new thread each time", nil}
  def target(%Schedule{}, nil), do: {"Wakes a thread that's gone", nil}
  def target(%Schedule{}, title), do: {"Wakes", quoted(title)}

  @doc ~S"""
  The last run's words (`outcome/1`) and what the page links with them:
  `:thread` after "started" (the thread it started, by its title),
  `:settings` for a skip because scheduled work is off (the words link to
  Settings, where it is turned on), or nil.
  """
  @spec last(Schedule.outcome()) :: {String.t(), :thread | :settings | nil}
  def last("started"), do: {outcome("started"), :thread}
  def last("skipped_consent"), do: {outcome("skipped_consent"), :settings}
  def last(other), do: {outcome(other), nil}

  @doc ~S"""
  The flash after Run now, from what the firing did and the title of the
  thread it woke (nil for a new thread each time): "Started a thread.",
  ~s(Sent to "Fix the pump".), ~s(Queued for "Fix the pump", behind its
  run.), or a skip's reason as a sentence ("Skipped: the last thread was
  still running.").
  """
  @spec ran(Schedule.outcome(), String.t() | nil) :: String.t()
  def ran("started", _title), do: "Started a thread."
  def ran("sent", title), do: "Sent to #{thread(title)}."
  def ran("queued", title), do: "Queued for #{thread(title)}, behind its run."

  def ran("skipped_" <> _ = skip, _title) do
    {first, rest} = String.split_at(outcome(skip), 1)
    String.upcase(first) <> rest <> "."
  end

  def ran(_unknown, _title), do: "Ran it."

  defp thread(nil), do: "the thread"
  defp thread(title), do: quoted(title)

  defp quoted(title), do: ~s("#{title}")

  defp capitalize("every" <> rest), do: "Every" <> rest

  defp count(1, word), do: word
  defp count(n, word), do: "#{n} #{word}s"
end
