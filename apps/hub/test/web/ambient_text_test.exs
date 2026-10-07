defmodule PhotonWeb.AmbientTextTest do
  @moduledoc """
  The pages' words for ambient mode: the last firings' outcomes, the
  run-now flashes, what is waiting, when the timers fire next, the
  consent warning, the form's values, the home page's warnings and the
  review mark.
  """

  use Photon.Case, async: true

  alias Photon.Questions.Question
  alias Photon.Threads.Thread
  alias PhotonWeb.AmbientText

  @at ~U[2026-10-08 14:00:00Z]

  defp status(overrides) do
    Map.merge(
      %{
        on?: true,
        every_minutes: 180,
        next_digest_at: nil,
        next_review_at: nil,
        pending: %{new: 0, smaller: 0},
        last_digest: nil,
        last_review: nil,
        stopped: nil,
        consent?: true,
        thinks?: true,
        scripted?: false
      },
      overrides
    )
  end

  defp result(outcome, count \\ 0), do: %{at: @at, outcome: outcome, count: count}

  test "last/2 says what each digest firing did" do
    assert AmbientText.last("digest", result("sent", 3)) == "sent 3 changes."
    assert AmbientText.last("digest", result("sent", 1)) == "sent 1 change."

    assert AmbientText.last("digest", result("queued", 2)) ==
             "sent 2 changes, after what Blip was doing."

    assert AmbientText.last("digest", result("skipped_nothing")) == "nothing new, skipped."

    assert AmbientText.last("digest", result("skipped_consent")) ==
             "skipped, schedules can't use your plan."

    assert AmbientText.last("digest", result("skipped_queued")) ==
             "Blip still had the last one waiting, skipped."

    assert AmbientText.last("digest", result("skipped_model")) ==
             "skipped, Blip wasn't signed in to ChatGPT."

    assert AmbientText.last("digest", result("off")) == "ambient mode was off."
    assert AmbientText.last("digest", result("something_new")) == "ran."
    assert AmbientText.last_label("digest") == "Last digest"
  end

  test "last/2 says what each review firing did" do
    assert AmbientText.last("review", result("sent", 2)) == "sent 2 threads."
    assert AmbientText.last("review", result("sent", 1)) == "sent 1 thread."

    assert AmbientText.last("review", result("skipped_nothing")) ==
             "no threads to review, skipped."

    assert AmbientText.last("review", result("skipped_consent")) ==
             "skipped, schedules can't use your plan."

    assert AmbientText.last_label("review") == "Last review"
  end

  test "ran/2 is the flash after a run-now button" do
    assert AmbientText.ran("digest", result("sent", 3)) == "Sent Blip a digest of 3 changes."
    assert AmbientText.ran("digest", result("sent", 1)) == "Sent Blip a digest of 1 change."

    assert AmbientText.ran("digest", result("queued", 2)) ==
             "Queued a digest of 2 changes for Blip, after what it's doing."

    assert AmbientText.ran("digest", result("skipped_nothing")) ==
             "Nothing new since the last digest."

    assert AmbientText.ran("digest", result("skipped_queued")) ==
             "Blip still has the last digest waiting."

    assert AmbientText.ran("review", result("sent", 2)) == "Sent Blip a review of 2 threads."
    assert AmbientText.ran("review", result("sent", 1)) == "Sent Blip a review of 1 thread."
    assert AmbientText.ran("review", result("skipped_nothing")) == "No threads need a review."

    assert AmbientText.ran("review", result("skipped_queued")) ==
             "Blip still has the last review waiting."

    assert AmbientText.ran("digest", result("off")) == "Turn on ambient mode first."
    assert AmbientText.ran("review", result("off")) == "Turn on ambient mode first."

    assert AmbientText.ran("digest", result("skipped_consent")) ==
             "Skipped: schedules can't use your plan."

    assert AmbientText.ran("review", result("skipped_model")) ==
             "Skipped: Blip isn't signed in to ChatGPT."
  end

  test "ran_kind/1 marks a run-now that needs something changed first as an error" do
    for outcome <- ~w(off skipped_consent skipped_model),
        do: assert(AmbientText.ran_kind(result(outcome)) == :error)

    for outcome <- ~w(sent queued skipped_nothing skipped_queued),
        do: assert(AmbientText.ran_kind(result(outcome)) == :info)
  end

  test "pending/1 says what waits, new and seen, in the owner's words" do
    assert AmbientText.pending(%{new: 0, smaller: 0}) == "Nothing new yet."
    assert AmbientText.pending(%{new: 2, smaller: 0}) == "2 changes waiting."
    assert AmbientText.pending(%{new: 1, smaller: 0}) == "1 change waiting."

    assert AmbientText.pending(%{new: 2, smaller: 3}) ==
             "2 changes waiting, and 3 you've seen or made yourself."

    assert AmbientText.pending(%{new: 1, smaller: 1}) ==
             "1 change waiting, and 1 you've seen or made yourself."

    assert AmbientText.pending(%{new: 0, smaller: 3}) ==
             "Nothing new yet. 3 changes you've seen or made yourself wait for the next " <>
               "digest with something new."

    assert AmbientText.pending(%{new: 0, smaller: 1}) ==
             "Nothing new yet. 1 change you've seen or made yourself waits for the next " <>
               "digest with something new."

    for n <- [0, 1, 3],
        new <- [0, 2],
        do: refute(AmbientText.pending(%{new: new, smaller: n}) =~ "smaller")
  end

  test "next/1 is a sentence with a part for each running timer" do
    digest = ~U[2026-10-08 17:00:00Z]
    review = ~U[2026-10-09 09:00:00Z]

    assert AmbientText.next(status(%{next_digest_at: digest, next_review_at: review})) == [
             "Next digest around ",
             {:time, "digest-at", digest},
             "; next review ",
             {:time, "review-at", review},
             "."
           ]

    assert AmbientText.next(status(%{next_digest_at: digest})) ==
             ["Next digest around ", {:time, "digest-at", digest}, "."]

    assert AmbientText.next(status(%{next_review_at: review})) ==
             ["Next review ", {:time, "review-at", review}, "."]

    assert AmbientText.next(status(%{})) == nil
  end

  test "needs_consent?/1 warns only when on, without consent, off the scripted model" do
    assert AmbientText.needs_consent?(status(%{consent?: false}))
    refute AmbientText.needs_consent?(status(%{on?: false, consent?: false}))
    refute AmbientText.needs_consent?(status(%{consent?: true}))
    refute AmbientText.needs_consent?(status(%{consent?: false, scripted?: true}))
    # Signed out, the consent box isn't on the page; needs_model?/1 warns.
    refute AmbientText.needs_consent?(status(%{consent?: false, thinks?: false}))
    assert AmbientText.needs_consent() =~ "Let schedules use my plan while I'm away"
  end

  test "needs_model?/1 warns while it is on and Blip can't reach ChatGPT" do
    assert AmbientText.needs_model?(status(%{thinks?: false}))
    refute AmbientText.needs_model?(status(%{on?: false, thinks?: false}))
    refute AmbientText.needs_model?(status(%{}))
    assert AmbientText.needs_model() =~ "skip until you sign in again"
  end

  test "skipping/1 warns Home while the last digest or review skipped for consent" do
    skipped = result("skipped_consent")

    assert AmbientText.skipping(status(%{consent?: false, last_digest: skipped})) == :consent

    assert AmbientText.skipping(
             status(%{consent?: false, last_digest: result("sent", 2), last_review: skipped})
           ) == :consent

    # Not once the owner allows it, nor while it is off, nor for other skips.
    assert AmbientText.skipping(status(%{consent?: true, last_review: skipped})) == nil

    assert AmbientText.skipping(status(%{on?: false, consent?: false, last_digest: skipped})) ==
             nil

    assert AmbientText.skipping(
             status(%{consent?: false, last_digest: result("skipped_nothing")})
           ) == nil

    assert AmbientText.skipping(status(%{consent?: false})) == nil

    assert AmbientText.skipping_text(:consent) =~
             "schedules can't use your plan while you're away"
  end

  test "skipping/1 warns Home while digests skip because Blip isn't signed in" do
    skipped = result("skipped_model")

    assert AmbientText.skipping(status(%{thinks?: false, last_review: skipped})) == :signed_out
    # Signed in again: the warning goes before the next firing.
    assert AmbientText.skipping(status(%{last_review: skipped})) == nil

    assert AmbientText.skipping(status(%{on?: false, thinks?: false, last_review: skipped})) ==
             nil

    assert AmbientText.skipping_text(:signed_out) ==
             "Digests and reviews are skipping: Blip isn't signed in to ChatGPT."
  end

  test "home_stopped?/1 warns Home while a timer is stopped" do
    assert AmbientText.home_stopped?(status(%{stopped: %{job: "review", reason: "boom"}}))
    refute AmbientText.home_stopped?(status(%{}))

    refute AmbientText.home_stopped?(
             status(%{on?: false, stopped: %{job: "digest", reason: "boom"}})
           )

    assert AmbientText.home_stopped() ==
             "Ambient mode stopped after an error. Save settings to start it again."
  end

  test "form_values/1 carries the saved switch and interval back into the form" do
    assert AmbientText.form_values(status(%{})) == %{
             "ambient" => "true",
             "ambient_every" => "180"
           }

    assert AmbientText.form_values(status(%{on?: false, every_minutes: 60})) ==
             %{"ambient" => "false", "ambient_every" => "60"}
  end

  test "every_options/1 and every/1 name the intervals" do
    assert AmbientText.every_options([60, 180, 360]) == [
             {"Every hour", "60"},
             {"Every 3 hours", "180"},
             {"Every 6 hours", "360"}
           ]

    assert AmbientText.every(90) == "Every 90 minutes"
  end

  test "stopped/1 says which timer stopped and how to start it again" do
    assert AmbientText.stopped(%{job: "digest", reason: "boom"}) ==
             "Digests stopped after an error: boom. Save settings to start them again."

    assert AmbientText.stopped(%{job: "review", reason: "boom"}) ==
             "The daily review stopped after an error: boom. Save settings to start it again."
  end

  test "the hint says what it does and what it costs" do
    assert AmbientText.hint() =~ "around 9 each morning"
    assert AmbientText.hint() =~ "a run on your ChatGPT plan"
  end

  describe "reviewed?/1" do
    defp board_entry(thread, questions \\ []), do: %{thread: thread, questions: questions}

    defp ago(days), do: DateTime.add(@at, -days * 86_400, :second)

    test "is true for a review since the thread's last touch" do
      thread = %Thread{last_run_ended_at: ago(4), active_at: ago(5), reviewed_at: ago(0)}
      assert AmbientText.reviewed?(board_entry(thread))
    end

    test "is false with no review, or one before the last touch" do
      refute AmbientText.reviewed?(board_entry(%Thread{last_run_ended_at: ago(4)}))

      thread = %Thread{last_run_ended_at: ago(1), reviewed_at: ago(2)}
      refute AmbientText.reviewed?(board_entry(thread))
    end

    test "counts a question passed to the owner after the review as a touch" do
      thread = %Thread{last_run_ended_at: ago(5), reviewed_at: ago(3)}
      refute AmbientText.reviewed?(board_entry(thread, [%Question{passed_at: ago(1)}]))
      assert AmbientText.reviewed?(board_entry(thread, [%Question{passed_at: ago(4)}]))
    end
  end
end
