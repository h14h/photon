defmodule PhotonWeb.ScheduleText do
  @moduledoc """
  The words the pages use for schedules: how often one repeats ("every
  day"), what its last firing did ("skipped: scheduled work is off"), and
  its when line for each state ("Every day · next", "Done", "Stopped after
  an error: ...").

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

  defp capitalize("every" <> rest), do: "Every" <> rest

  defp count(1, word), do: word
  defp count(n, word), do: "#{n} #{word}s"
end
