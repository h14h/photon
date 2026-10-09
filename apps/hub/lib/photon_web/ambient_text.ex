defmodule PhotonWeb.AmbientText do
  @moduledoc """
  The pages' words for ambient mode: the Settings section's hint,
  warnings and status block, the run-now flashes, and the home page's
  warnings.

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
  Whether to warn that digests and reviews will skip for consent: ambient
  mode is on, Blip can reach its model (else `needs_model?/1` warns and
  the consent box isn't shown), Settings doesn't let schedules use the
  owner's plan, and the hub isn't on the scripted model (which needs no
  consent).
  """
  @spec needs_consent?(Ambient.status()) :: boolean()
  def needs_consent?(%{on?: on?, thinks?: thinks?, consent?: consent?, scripted?: scripted?}),
    do: on? and thinks? and not consent? and not scripted?

  @doc """
  Whether to warn, with ambient mode on, that digests and reviews will
  skip because Blip can't reach ChatGPT (signed out, or plan use not
  allowed).
  """
  @spec needs_model?(Ambient.status()) :: boolean()
  def needs_model?(%{on?: on?, thinks?: thinks?}), do: on? and not thinks?

  @doc "The warning shown while it is on but Blip can't reach ChatGPT."
  @spec needs_model() :: String.t()
  def needs_model do
    "Blip isn't signed in to ChatGPT, so digests and reviews skip until you sign in again " <>
      "above. You can still turn ambient mode off here."
  end

  @doc """
  The saved ambient values, to merge into the settings map the form
  starts from so a Save sends them back unchanged.
  """
  @spec form_values(Ambient.status()) :: %{String.t() => String.t()}
  def form_values(%{on?: on?, every_minutes: every_minutes}),
    do: %{"ambient" => to_string(on?), "ambient_every" => to_string(every_minutes)}

  @doc ~S(The digest interval's select options, from the minutes offered: {"Every hour", "60"}.)
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
  changes new to the owner, and the ones they have seen or made
  themselves, which only go along with something new.
  """
  @spec pending(%{new: non_neg_integer(), smaller: non_neg_integer()}) :: String.t()
  def pending(%{new: 0, smaller: 0}), do: "Nothing new yet."

  def pending(%{new: 0, smaller: seen}) do
    verb = if seen == 1, do: "waits", else: "wait"

    "Nothing new yet. #{count(seen, "change")} you've seen or made yourself #{verb} " <>
      "for the next digest with something new."
  end

  def pending(%{new: new, smaller: 0}), do: "#{count(new, "change")} waiting."

  def pending(%{new: new, smaller: seen}),
    do: "#{count(new, "change")} waiting, and #{seen} you've seen or made yourself."

  @doc ~S(The heading of a last firing, before its time: "Last digest" or "Last review".)
  @spec last_label(String.t()) :: String.t()
  def last_label("digest"), do: "Last digest"
  def last_label(_review), do: "Last review"

  @doc ~S"""
  What a last firing did, to follow its time ("sent 3 changes."). An
  outcome this version doesn't know reads as "ran.".
  """
  @spec last(String.t(), Ambient.result()) :: String.t()
  def last(job, %{outcome: "sent", count: n}), do: "sent #{count(n, noun(job))}."

  def last(job, %{outcome: "queued", count: n}),
    do: "sent #{count(n, noun(job))}, after what Blip was doing."

  def last("digest", %{outcome: "skipped_nothing"}), do: "nothing new, skipped."
  def last(_review, %{outcome: "skipped_nothing"}), do: "no threads to review, skipped."
  def last(_job, %{outcome: "skipped_consent"}), do: "skipped, schedules can't use your plan."
  def last(_job, %{outcome: "skipped_model"}), do: "skipped, Blip wasn't signed in to ChatGPT."

  def last(_job, %{outcome: "skipped_queued"}),
    do: "Blip still had the last one waiting, skipped."

  def last(_job, %{outcome: "off"}), do: "ambient mode was off."
  def last(_job, _result), do: "ran."

  @doc "A timer that stopped after an error: its reason, and how to start it again."
  @spec stopped(Ambient.stopped()) :: String.t()
  def stopped(%{job: "review", reason: reason}),
    do: "The daily review stopped after an error: #{reason}. Save settings to start it again."

  def stopped(%{reason: reason}),
    do: "Digests stopped after an error: #{reason}. Save settings to start them again."

  @doc """
  The flash after a run-now button, from what
  `Photon.Ambient.digest_now/0` or `review_now/0` returned.
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
  def ran(_job, %{outcome: "skipped_model"}), do: "Skipped: Blip isn't signed in to ChatGPT."
  def ran(_job, _result), do: "Done."

  @doc """
  The flash's kind for `ran/2`'s words: `:error` when nothing was sent
  because something has to change first (ambient mode is off, or Blip
  can't use the plan), so no check mark shows; else `:info`.
  """
  @spec ran_kind(Ambient.result()) :: :info | :error
  def ran_kind(%{outcome: outcome}) when outcome in ~w(off skipped_consent skipped_model),
    do: :error

  def ran_kind(_result), do: :info

  @doc """
  Why the home page warns that digests and reviews are skipping, or nil:
  ambient mode is on, and the last digest or the last review was skipped
  because Blip wasn't signed in to ChatGPT and it still isn't
  (`:signed_out`), or because schedules couldn't use the owner's plan and
  Settings still doesn't let them (`:consent`). Once the owner signs in or
  allows it, the warning goes before the next firing.
  """
  @spec skipping(Ambient.brief()) :: :signed_out | :consent | nil
  def skipping(%{on?: true} = status) do
    cond do
      not status.thinks? and skipped?(status, "skipped_model") -> :signed_out
      not status.consent? and skipped?(status, "skipped_consent") -> :consent
      true -> nil
    end
  end

  def skipping(_status), do: nil

  @doc "The home page's warning while digests and reviews skip (`skipping/1`)."
  @spec skipping_text(:signed_out | :consent) :: String.t()
  def skipping_text(:signed_out),
    do: "Digests and reviews are skipping: Blip isn't signed in to ChatGPT."

  def skipping_text(:consent),
    do: "Digests and reviews are skipping: schedules can't use your plan while you're away."

  defp skipped?(%{last_digest: digest, last_review: review}, outcome),
    do: Enum.any?([digest, review], &match?(%{outcome: ^outcome}, &1))

  @doc "Whether the home page warns that a timer stopped after an error."
  @spec home_stopped?(Ambient.brief()) :: boolean()
  def home_stopped?(%{on?: true, stopped: %{}}), do: true
  def home_stopped?(_status), do: false

  @doc "The home page's warning after a timer stopped (the reason is on the Settings page)."
  @spec home_stopped() :: String.t()
  def home_stopped, do: "Ambient mode stopped after an error. Save settings to start it again."

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
