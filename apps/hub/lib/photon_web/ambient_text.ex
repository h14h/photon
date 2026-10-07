defmodule PhotonWeb.AmbientText do
  @moduledoc """
  The pages' words for ambient mode (sections 2.2, 7.2 and 7.3 of
  `docs/plans/step-5-ambient-mode.md`): the Settings section's hint and
  warnings, the digest intervals, the status block (when the next digest
  and review come, what is waiting, what the last ones did, a timer that
  stopped), the flashes of the scripted model's run-now buttons, and
  whether a home page row was in Blip's review.

  Pure, over `Photon.Ambient.status/0` and board entries. Times are never
  formatted here: the browser knows the owner's time zone, so a page
  renders each time with `PhotonWeb.TimeComponents.local_time/1` next to
  these words (`next/1` says where).
  """

  alias Photon.{Ambient, Threads}
  alias Photon.Threads.State

  @typedoc "One piece of a sentence: words, or a time the page renders locally under the ID's suffix."
  @type part :: String.t() | {:time, String.t(), DateTime.t()}

  @doc "The checkbox's hint: what each setting does, and what it costs."
  @spec hint() :: String.t()
  def hint do
    "Off, Blip hears about work it started, failures, and questions for you, as it does now. " <>
      "On, it also reads a digest of what changed in your projects every few hours, and around 9 " <>
      "each morning looks over threads left stopped, failed or waiting on you. It tells you what's " <>
      "worth knowing in its chat. Each digest and review is a run on your ChatGPT plan: digests " <>
      "are skipped when nothing new happened, and both are skipped while schedules can't use " <>
      "your plan."
  end

  @doc "The warning shown while it is on but schedules can't use the owner's plan."
  @spec needs_consent() :: String.t()
  def needs_consent do
    "Schedules can't use your plan while you're away, so digests and reviews will skip. " <>
      "Turn on “Let schedules use my plan while I'm away” above."
  end

  @doc """
  Whether to warn that digests and reviews will skip: ambient mode is on,
  Settings doesn't let schedules use the owner's plan, and the hub isn't
  on the scripted model (which needs no consent).
  """
  @spec needs_consent?(Ambient.status()) :: boolean()
  def needs_consent?(%{on?: on?, consent?: consent?, scripted?: scripted?}),
    do: on? and not consent? and not scripted?

  @doc """
  The form's ambient values from the saved setting, for merging into the
  settings map the form starts from, so a Save sends them back as they
  are.
  """
  @spec form_values(Ambient.status()) :: %{String.t() => String.t()}
  def form_values(%{on?: on?, every_minutes: every_minutes}),
    do: %{"ambient" => to_string(on?), "ambient_every" => to_string(every_minutes)}

  @doc ~S"""
  The digest interval's options for a select, from the minutes offered:
  `{"Every hour", "60"}`, `{"Every 3 hours", "180"}`.
  """
  @spec every_options([pos_integer()]) :: [{String.t(), String.t()}]
  def every_options(minutes), do: Enum.map(minutes, &{every(&1), to_string(&1)})

  @doc ~S(An interval in minutes as words: "Every hour", "Every 3 hours", "Every 90 minutes".)
  @spec every(pos_integer()) :: String.t()
  def every(60), do: "Every hour"
  def every(minutes) when rem(minutes, 60) == 0, do: "Every #{div(minutes, 60)} hours"
  def every(minutes), do: "Every #{minutes} minutes"

  @doc """
  When the timers fire next, as a sentence of parts (`t:part/0`): "Next
  digest around <time>; next review <time>." Leaves out a timer that isn't
  running, and is nil when neither is.
  """
  @spec next(Ambient.status()) :: [part()] | nil
  def next(%{next_digest_at: nil, next_review_at: nil}), do: nil

  def next(%{next_digest_at: nil, next_review_at: review}),
    do: ["Next review ", {:time, "review-at", review}, "."]

  def next(%{next_digest_at: digest, next_review_at: nil}),
    do: ["Next digest around ", {:time, "digest-at", digest}, "."]

  def next(%{next_digest_at: digest, next_review_at: review}) do
    [
      "Next digest around ",
      {:time, "digest-at", digest},
      "; next review ",
      {:time, "review-at", review},
      "."
    ]
  end

  @doc """
  What waits for the next digest, counted by the digest's own rule:
  changes new to the owner, and smaller ones that only ride along.
  """
  @spec pending(%{new: non_neg_integer(), smaller: non_neg_integer()}) :: String.t()
  def pending(%{new: 0, smaller: 0}), do: "Nothing new yet."

  def pending(%{new: 0, smaller: smaller}) do
    verb = if smaller == 1, do: "waits", else: "wait"
    "#{count(smaller, "smaller change")} #{verb} for the next digest with something new."
  end

  def pending(%{new: new, smaller: 0}), do: "#{count(new, "change")} waiting."

  def pending(%{new: new, smaller: smaller}) do
    ones = if smaller == 1, do: "smaller one", else: "smaller ones"
    "#{count(new, "change")} waiting, and #{smaller} #{ones}."
  end

  @doc ~S"""
  The heading of a last firing, before its time: "Last digest" or "Last
  review".
  """
  @spec last_label(String.t()) :: String.t()
  def last_label("digest"), do: "Last digest"
  def last_label(_review), do: "Last review"

  @doc ~S"""
  What a last firing did, to follow its time: "sent 3 changes.", "nothing
  new, skipped.", "skipped, schedules can't use your plan.", "Blip still
  had the last one waiting, skipped." An outcome this version doesn't know
  reads as "ran.".
  """
  @spec last(String.t(), Ambient.result()) :: String.t()
  def last(job, %{outcome: "sent", count: n}), do: "sent #{count(n, noun(job))}."

  def last(job, %{outcome: "queued", count: n}),
    do: "sent #{count(n, noun(job))}, after what Blip was doing."

  def last("digest", %{outcome: "skipped_nothing"}), do: "nothing new, skipped."
  def last(_review, %{outcome: "skipped_nothing"}), do: "no threads to review, skipped."
  def last(_job, %{outcome: "skipped_consent"}), do: "skipped, schedules can't use your plan."

  def last(_job, %{outcome: "skipped_queued"}),
    do: "Blip still had the last one waiting, skipped."

  def last(_job, %{outcome: "off"}), do: "ambient mode was off."
  def last(_job, _result), do: "ran."

  @doc ~S"""
  A timer that stopped after an error: "Digests stopped after an error:
  <reason>. Save settings to start them again." (or "The daily review
  stopped ...").
  """
  @spec stopped(Ambient.stopped()) :: String.t()
  def stopped(%{job: "review", reason: reason}),
    do: "The daily review stopped after an error: #{reason}. Save settings to start it again."

  def stopped(%{reason: reason}),
    do: "Digests stopped after an error: #{reason}. Save settings to start them again."

  @doc ~S"""
  The flash after "Send a digest now" or "Run the review now", from what
  `Photon.Ambient.digest_now/0` or `review_now/0` returned: "Sent Blip a
  digest of 3 changes.", "Nothing new since the last digest.", "Turn on
  ambient mode first."
  """
  @spec ran(String.t(), Ambient.result()) :: String.t()
  def ran(_job, %{outcome: "off"}), do: "Turn on ambient mode first."

  def ran("digest", %{outcome: "sent", count: n}),
    do: "Sent Blip a digest of #{count(n, "change")}."

  def ran("digest", %{outcome: "queued", count: n}),
    do: "Queued a digest of #{count(n, "change")} for Blip, after what it's doing."

  def ran("digest", %{outcome: "skipped_nothing"}), do: "Nothing new since the last digest."
  def ran("digest", %{outcome: "skipped_queued"}), do: "Blip still has the last digest waiting."

  def ran(_review, %{outcome: "sent", count: n}),
    do: "Sent Blip a review of #{count(n, "thread")}."

  def ran(_review, %{outcome: "queued", count: n}),
    do: "Queued a review of #{count(n, "thread")} for Blip, after what it's doing."

  def ran(_review, %{outcome: "skipped_nothing"}), do: "No threads need a review."
  def ran(_review, %{outcome: "skipped_queued"}), do: "Blip still has the last review waiting."
  def ran(_job, %{outcome: "skipped_consent"}), do: "Skipped: schedules can't use your plan."
  def ran(_job, _result), do: "Done."

  @doc """
  Whether a board entry's thread was raised in a review since it was last
  touched: it has a `reviewed_at` no earlier than its last activity and
  the last question passed to the owner. Touching it again (a message, a
  run, an answer) ends that.
  """
  @spec reviewed?(Threads.board_entry()) :: boolean()
  def reviewed?(%{thread: %{reviewed_at: %DateTime{} = reviewed}} = entry) do
    case last_touch(entry) do
      nil -> true
      touch -> DateTime.compare(reviewed, touch) != :lt
    end
  end

  def reviewed?(_entry), do: false

  # The same last touch the review reads (`Photon.Ambient.Rules`): the
  # thread's last activity, or the last question passed to the owner.
  defp last_touch(entry) do
    passed = entry |> Map.get(:questions, []) |> Enum.map(&Map.get(&1, :passed_at))

    [State.last_activity(entry.thread) | passed]
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp noun("digest"), do: "change"
  defp noun(_review), do: "thread"

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"
end
