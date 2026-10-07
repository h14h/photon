defmodule Photon.Ambient.TextTest do
  @moduledoc "The words of digests and daily reviews (sections 3.4 and 4.4 of the step 5 plan)."

  use Photon.Case, async: true

  alias Photon.Ambient.Text

  @now ~U[2026-10-07 15:00:00.000000Z]

  defp ago(hours), do: DateTime.add(@now, -hours * 3600, :second)

  defp row(kind, new?, fields) do
    Map.merge(
      %{
        kind: kind,
        new?: new?,
        at: ago(1),
        thread_id: nil,
        title: nil,
        project_id: "p_garden",
        slug: "garden",
        project: "Garden",
        note: nil,
        schedule_id: nil,
        prompt: nil,
        reason: nil,
        name: nil,
        writer: nil,
        writer_title: nil,
        deleted?: false
      },
      Map.new(fields)
    )
  end

  defp pump(fields \\ []) do
    row(
      "finished",
      true,
      Keyword.merge(
        [
          thread_id: "c_123",
          title: "Fix the pump",
          note: "Replaced the fuse and the pump runs again."
        ],
        fields
      )
    )
  end

  defp gutters,
    do:
      row("schedule_stopped", true,
        schedule_id: "sc_9",
        prompt: "check the gutters",
        reason: "the thread's project no longer exists."
      )

  defp smaller_rows do
    [
      row("finished", false, thread_id: "c_321", title: "Order seeds", note: "Ordered."),
      row("file_written", false, name: "notes.md", writer: "c_123", writer_title: "Fix the pump"),
      row("file_written", false,
        project: "House",
        slug: "house",
        name: "colours.md",
        writer: "user"
      ),
      row("project_created", false, project: "Shed", slug: "shed"),
      row("thread_started", false, thread_id: "c_789", title: "Gutters", project: "House"),
      row("resolved", false, thread_id: "c_222", title: "Old pump"),
      row("purpose_changed", false, [])
    ]
  end

  defp digest(new, smaller, overrides \\ []) do
    Map.merge(
      %{
        new: new,
        smaller: smaller,
        more_new: 0,
        more_smaller: 0,
        gone: [],
        snapshot: %{running: 2, waiting: 1, failed: 1}
      },
      Map.new(overrides)
    )
  end

  @doc_sent %{
    "last_sent_at" => "2026-10-07T12:00:00.000000Z",
    "on_since" => "2026-10-01T08:00:00Z"
  }

  describe "digest/2" do
    test "the whole text" do
      text =
        Text.digest(
          digest([pump(), gutters()], smaller_rows(), more_new: 4, more_smaller: 3),
          @doc_sent
        )

      assert text == """
             [Digest] Since the last digest (2026-10-07 12:00 UTC), in your user's projects.
             New to the user:
             - Garden / "Fix the pump" (c_123) finished. It said: Replaced the fuse and the pump runs again.
             - Garden / schedule sc_9 "check the gutters" stopped after an error: the thread's project no longer exists.
             ...and 4 more; list_threads with state unread shows them.
             Already seen by the user, or done by them:
             - Garden / "Order seeds" (c_321) finished; the user has seen it.
             - Garden / context file notes.md written by "Fix the pump" (c_123).
             - House / context file colours.md written by the user.
             - The user started project Shed.
             - The user started "Gutters" (c_789) in House.
             - The user resolved Garden / "Old pump" (c_222).
             - The user edited project Garden's name or Purpose.
             ...and 3 more smaller changes.
             Now: 2 running, 1 waiting on the user, 1 failed.\
             """
    end

    test "leaves out the \"Already seen\" block when it is empty" do
      text = Text.digest(digest([pump()], []), @doc_sent)
      refute text =~ "Already seen"
      refute text =~ "...and"
    end

    test "before the first digest it names when ambient mode was turned on" do
      text = Text.digest(digest([pump()], []), %{"on_since" => "2026-10-01T08:00:00Z"})
      assert text =~ "[Digest] Since ambient mode was turned on (2026-10-01 08:00 UTC), in your"
    end

    test "names last_sent_at, not a skipped firing in between" do
      doc =
        Map.put(@doc_sent, "last_digest", %{
          "at" => "2026-10-07T14:00:00Z",
          "outcome" => "skipped_nothing",
          "count" => 1
        })

      assert Text.digest(digest([pump()], []), doc) =~
               "Since the last digest (2026-10-07 12:00 UTC)"
    end

    test "the Now line leaves out zeros, and says so when all are zero" do
      some =
        Text.digest(
          digest([pump()], [], snapshot: %{running: 0, waiting: 0, failed: 3}),
          @doc_sent
        )

      assert String.ends_with?(some, "\nNow: 3 failed.")

      none =
        Text.digest(
          digest([pump()], [], snapshot: %{running: 0, waiting: 0, failed: 0}),
          @doc_sent
        )

      assert String.ends_with?(none, "\nNow: nothing running or waiting.")
    end

    test "Blip's own schedule, a deleted file and a run with no note" do
      text =
        Text.digest(
          digest(
            [
              pump(note: nil),
              %{gutters() | project: nil, project_id: nil, slug: nil, reason: nil}
            ],
            [row("file_written", false, name: "old.md", writer: "user", deleted?: true)]
          ),
          @doc_sent
        )

      assert text =~ ~s{- Garden / "Fix the pump" (c_123) finished.\n}
      assert text =~ ~s{- Your schedule sc_9 "check the gutters" stopped after an error.\n}
      assert text =~ "- Garden / context file old.md deleted by the user."
    end

    test "notes are cut to 280 characters" do
      text = Text.digest(digest([pump(note: String.duplicate("word ", 200))], []), @doc_sent)
      [line] = text |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "- Garden"))
      [_head, note] = String.split(line, "It said: ")
      assert String.length(note) == 280
      assert String.ends_with?(note, "...")
    end

    test "the whole text is at most 6,000 characters, and rows that don't fit are counted" do
      long = String.duplicate("x", 300)

      new =
        for n <- 1..20,
            do: pump(thread_id: "c_#{n}", title: String.slice(long, 0, 60), note: long)

      smaller =
        for n <- 1..15, do: row("file_written", false, name: "#{long}#{n}.md", writer: "user")

      text = Text.digest(digest(new, smaller, more_new: 2), @doc_sent)

      assert String.length(text) <= 6_000
      assert text =~ ~r/\.\.\.and \d+ more; list_threads/
      assert text =~ ~r/\.\.\.and \d+ more smaller changes\./
      assert String.ends_with?(text, "Now: 2 running, 1 waiting on the user, 1 failed.")
    end
  end

  describe "digest_ref/2" do
    test "one item per row, new first, with the more counts" do
      ref =
        Text.digest_ref(
          digest([pump(), gutters()], smaller_rows(), more_new: 4, more_smaller: 3),
          "digest:t:3"
        )

      assert %{"kind" => "digest", "key" => "digest:t:3", "more" => 4, "more_smaller" => 3} = ref
      assert length(ref["items"]) == 9

      assert [finished, schedule, seen, file | _rest] = ref["items"]

      assert finished == %{
               "kind" => "finished",
               "new" => true,
               "thread_id" => "c_123",
               "title" => "Fix the pump",
               "project_id" => "p_garden",
               "slug" => "garden",
               "project" => "Garden",
               "note" => "Replaced the fuse and the pump runs again."
             }

      assert %{"schedule_id" => "sc_9", "prompt" => "check the gutters", "new" => true} = schedule
      assert %{"kind" => "finished", "new" => false} = seen
      refute Map.has_key?(seen, "note")

      assert %{
               "kind" => "file_written",
               "name" => "notes.md",
               "writer" => "c_123",
               "deleted" => false
             } =
               file
    end
  end

  describe "digest_older/2" do
    test "the counts and the new subjects" do
      older = Text.digest_older(digest([pump(), gutters()], smaller_rows()), @now)

      assert older == %{
               "text" =>
                 ~s([Digest delivered 2026-10-07 15:00 UTC: 2 new, 7 smaller. New: Garden / "Fix the pump", Garden / schedule "check the gutters".]),
               "drop_if_answer" => "[nothing to tell]"
             }
    end

    test "at most five subjects and 300 characters, with how many more" do
      new = for n <- 1..8, do: pump(thread_id: "c_#{n}", title: "Thread number #{n}")
      text = Text.digest_older(digest(new, []), @now)["text"]

      assert text =~ "8 new. New: "
      assert text =~ ~s{"Thread number 5", and 3 more.]}
      refute text =~ "Thread number 6"

      long =
        for n <- 1..5, do: pump(thread_id: "c_#{n}", title: String.duplicate("long title ", 10))

      text = Text.digest_older(digest(long, []), @now)["text"]
      assert String.length(text) <= 300
      assert text =~ "more.]"
    end
  end

  describe "review/3, review_ref/2, review_older/2" do
    defp review_row({id, title, project}, state, hours, fields) do
      Map.merge(
        %{
          thread_id: id,
          title: title,
          project_id: "p_" <> String.downcase(project),
          slug: String.downcase(project),
          project: project,
          state: state,
          since: ago(hours),
          last_run_status: nil,
          detail: nil
        },
        Map.new(fields)
      )
    end

    defp review do
      %{
        rows: [
          review_row({"c_123", "Fix the pump", "Garden"}, :quiet, 4 * 24 + 2,
            last_run_status: "stopped"
          ),
          review_row({"c_456", "Gutters", "House"}, :failed, 5 * 24,
            last_run_status: "failed",
            detail: "the ladder machine is offline."
          ),
          review_row({"c_789", "Paint", "House"}, :waiting, 3 * 24 + 5,
            detail: "Which white, Chalk or Linen?"
          )
        ],
        more: 2,
        quiet_after: 72 * 3600
      }
    end

    test "the whole text" do
      text = Text.review(review(), %{"c_123" => "Draining the tank first."}, @now)

      assert text == """
             [Daily review] 5 threads have sat untouched for 3 days or more:
             - Garden / "Fix the pump" (c_123): stopped 4 days ago. It last said: Draining the tank first.
             - House / "Gutters" (c_456): failed 5 days ago: the ladder machine is offline.
             - House / "Paint" (c_789): waiting on the user for 3 days: Which white, Chalk or Linen?
             ...and 2 more; list_threads with state quiet shows them.\
             """
    end

    test "one thread, no answer, and a quiet_after under an hour" do
      [row | _rest] = review().rows
      text = Text.review(%{rows: [%{row | since: ago(5)}], more: 0, quiet_after: 0}, %{}, @now)

      assert text == """
             [Daily review] 1 thread has sat untouched:
             - Garden / "Fix the pump" (c_123): stopped 5 hours ago.\
             """
    end

    test "lines are cut to 400 characters" do
      [row | _rest] = review().rows

      text =
        Text.review(
          %{rows: [row], more: 0, quiet_after: 3600},
          %{"c_123" => String.duplicate("a ", 400)},
          @now
        )

      [_header, line] = String.split(text, "\n")
      assert String.length(line) <= 400 and String.length(line) > 390
      assert String.ends_with?(line, "...")
    end

    test "the ref" do
      ref = Text.review_ref(review(), "review:t:1")

      assert %{"kind" => "review", "key" => "review:t:1", "more" => 2, "items" => [first | _rest]} =
               ref

      assert first == %{
               "thread_id" => "c_123",
               "title" => "Fix the pump",
               "project_id" => "p_garden",
               "slug" => "garden",
               "project" => "Garden",
               "state" => "quiet",
               "since" => DateTime.to_iso8601(ago(4 * 24 + 2))
             }
    end

    test "the older stub" do
      assert Text.review_older(review(), @now) == %{
               "text" =>
                 ~s([Daily review delivered 2026-10-07 15:00 UTC: Garden / "Fix the pump", House / "Gutters", House / "Paint", and 2 more.]),
               "drop_if_answer" => "[nothing to tell]"
             }
    end
  end

  describe "ago/2" do
    test "whole days, hours under a day, minutes under an hour" do
      assert Text.ago(ago(4 * 24 + 5), @now) == "4 days"
      assert Text.ago(ago(24), @now) == "1 day"
      assert Text.ago(ago(5), @now) == "5 hours"
      assert Text.ago(ago(1), @now) == "1 hour"
      assert Text.ago(DateTime.add(@now, -150, :second), @now) == "2 minutes"
      assert Text.ago(@now, @now) == "1 minute"
    end
  end
end
