defmodule PhotonWeb.AmbientTextTest do
  @moduledoc """
  The pages' words for ambient mode: the last firings' outcomes, the
  run-now flashes, what is waiting, when the timers fire next, the
  consent warning, the form's values and the review mark.
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
  end

  test "pending/1 says what waits, for each mix of new and smaller" do
    assert AmbientText.pending(%{new: 0, smaller: 0}) == "Nothing new yet."
    assert AmbientText.pending(%{new: 2, smaller: 0}) == "2 changes waiting."
    assert AmbientText.pending(%{new: 1, smaller: 0}) == "1 change waiting."

    assert AmbientText.pending(%{new: 2, smaller: 3}) ==
             "2 changes waiting, and 3 smaller ones."

    assert AmbientText.pending(%{new: 1, smaller: 1}) ==
             "1 change waiting, and 1 smaller one."

    assert AmbientText.pending(%{new: 0, smaller: 3}) ==
             "3 smaller changes wait for the next digest with something new."

    assert AmbientText.pending(%{new: 0, smaller: 1}) ==
             "1 smaller change waits for the next digest with something new."
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
    assert AmbientText.needs_consent() =~ "Let schedules use my plan while I'm away"
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
