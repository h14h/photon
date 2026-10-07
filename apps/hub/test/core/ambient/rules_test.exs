defmodule Photon.Ambient.RulesTest do
  @moduledoc "Ambient mode's decisions (sections 2.3, 3.3, 4.1 and 4.2 of the step 5 plan)."

  use Photon.Case, async: true

  alias Photon.Ambient.Rules

  @now ~U[2026-10-09 12:00:00.000000Z]
  @hour 3_600_000
  @day 24 * @hour

  @garden %{id: "p_garden", slug: "garden", name: "Garden"}
  @house %{id: "p_house", slug: "house", name: "House"}
  @places %{prompts: %{"sc_9" => "check the gutters"}, projects: [@garden, @house]}

  defp ms(at), do: DateTime.to_unix(at, :millisecond)
  defp ago(hours), do: DateTime.add(@now, -hours * 3600, :second)

  # A board entry for thread `id` in `project`, with thread fields.
  defp board_entry(id, state, project \\ @garden, fields \\ []) do
    thread =
      Map.merge(
        %{
          id: id,
          title: "Thread #{id}",
          active_at: ago(100),
          last_run_status: "stopped",
          last_run_ended_at: ago(100),
          last_run_note: nil,
          resolved_at: nil,
          reviewed_at: nil
        },
        Map.new(fields)
      )

    %{id: id, thread: thread, project: project, state: state, questions: []}
  end

  defp item(id, kind, fields) do
    Map.merge(
      %{
        id: id,
        key: "#{kind}:#{id}",
        kind: kind,
        thread_id: nil,
        project_id: nil,
        schedule_id: nil,
        name: nil,
        writer: nil,
        note: nil,
        inserted_at: ago(1)
      },
      Map.new(fields)
    )
  end

  defp finished(id, thread_id, at \\ ago(1)),
    do: item(id, "finished", thread_id: thread_id, project_id: "p_garden", inserted_at: at)

  describe "config/2" do
    test "the defaults, from an empty doc and no params" do
      assert Rules.config(%{}, %{}) == %{on?: false, every_minutes: 180, offset_minutes: 0}
    end

    test "reads each field from the form" do
      params = %{"ambient" => "true", "ambient_every" => "60", "utc_offset" => "-300"}

      assert Rules.config(params, %{}) == %{on?: true, every_minutes: 60, offset_minutes: -300}

      assert Rules.config(%{"ambient_every" => 360, "utc_offset" => 330}, %{}).every_minutes ==
               360

      assert Rules.config(%{"utc_offset" => " 330 "}, %{}).offset_minutes == 330
      assert Rules.config(%{"utc_offset" => "840"}, %{}).offset_minutes == 840
      assert Rules.config(%{"utc_offset" => "-720"}, %{}).offset_minutes == -720
    end

    test "junk keeps the doc's value" do
      doc = %{"on" => true, "every_minutes" => 60, "offset_minutes" => 120}

      for params <- [
            %{"ambient" => "yes", "ambient_every" => "90", "utc_offset" => "841"},
            %{"ambient" => nil, "ambient_every" => "abc", "utc_offset" => "-721"},
            %{"ambient" => 1, "ambient_every" => "60.5", "utc_offset" => "1.5"}
          ] do
        assert Rules.config(params, doc) == %{on?: true, every_minutes: 60, offset_minutes: 120}
      end
    end

    test "a missing \"ambient\" keeps it on, and keeps it off" do
      assert Rules.config(%{"ambient_every" => "60"}, %{"on" => true}).on? == true
      assert Rules.config(%{"ambient_every" => "60"}, %{"on" => false}).on? == false
      assert Rules.config(%{}, %{}).on? == false
    end

    test "an explicit \"false\" turns it off" do
      assert Rules.config(%{"ambient" => "false"}, %{"on" => true}).on? == false
    end

    test "a missing \"utc_offset\" keeps the doc's" do
      assert Rules.config(%{"ambient" => "true"}, %{"offset_minutes" => -300}).offset_minutes ==
               -300
    end

    test "odd values in the doc read as the defaults" do
      doc = %{"on" => "true", "every_minutes" => 45, "offset_minutes" => 5000}
      assert Rules.config(%{}, doc) == %{on?: false, every_minutes: 180, offset_minutes: 0}
      assert Rules.config(nil, nil) == %{on?: false, every_minutes: 180, offset_minutes: 0}
    end
  end

  describe "changes/3" do
    @on %{"on" => true, "every_minutes" => 180, "offset_minutes" => 0}
    @off %{"on" => false, "every_minutes" => 180, "offset_minutes" => 0}
    @both %{digest: true, review: true}
    @none %{digest: false, review: false}

    defp changes(doc, params, live), do: Rules.changes(doc, Rules.config(params, doc), live)

    test "off to off does nothing" do
      assert changes(@off, %{"ambient" => "false"}, @none) ==
               %{digest: :keep, review: :keep, clear?: false, turned_on?: false}
    end

    test "off to on arms both timers" do
      assert changes(@off, %{"ambient" => "true"}, @none) ==
               %{digest: :arm, review: :arm, clear?: false, turned_on?: true}
    end

    test "on to off retires both and clears what is pending" do
      assert changes(@on, %{"ambient" => "false"}, @both) ==
               %{digest: :retire, review: :retire, clear?: true, turned_on?: false}
    end

    test "on to off with a timer already gone retires only the live one" do
      assert %{digest: :keep, review: :retire, clear?: true} =
               changes(@on, %{"ambient" => "false"}, %{digest: false, review: true})
    end

    test "a new interval replaces only the digest timer" do
      assert changes(@on, %{"ambient" => "true", "ambient_every" => "60"}, @both) ==
               %{digest: :rearm, review: :keep, clear?: false, turned_on?: false}
    end

    test "a timer that isn't live is armed again" do
      assert %{digest: :arm, review: :keep} =
               changes(@on, %{"ambient" => "true"}, %{digest: false, review: true})

      assert %{digest: :keep, review: :arm} =
               changes(@on, %{"ambient" => "true"}, %{digest: true, review: false})
    end

    test "a new offset replaces only the review timer" do
      assert changes(@on, %{"ambient" => "true", "utc_offset" => "-300"}, @both) ==
               %{digest: :keep, review: :rearm, clear?: false, turned_on?: false}
    end

    test "on, nothing changed and both live: nothing" do
      assert changes(
               @on,
               %{"ambient" => "true", "ambient_every" => "180", "utc_offset" => "0"},
               @both
             ) ==
               %{digest: :keep, review: :keep, clear?: false, turned_on?: false}
    end

    test "params with no \"ambient\" key over an on doc change nothing" do
      assert changes(@on, %{"user_name" => "Henry"}, @both) ==
               %{digest: :keep, review: :keep, clear?: false, turned_on?: false}
    end
  end

  describe "next_review/2" do
    test "at offset 0, before and after today's 09:00" do
      assert Rules.next_review(ms(~U[2026-10-09 08:00:00Z]), 0) == ms(~U[2026-10-09 09:00:00Z])
      assert Rules.next_review(ms(~U[2026-10-09 09:00:00Z]), 0) == ms(~U[2026-10-10 09:00:00Z])
      assert Rules.next_review(ms(~U[2026-10-09 10:00:00Z]), 0) == ms(~U[2026-10-10 09:00:00Z])
    end

    test "at -300 (09:00 local is 14:00 UTC)" do
      assert Rules.next_review(ms(~U[2026-10-09 13:59:00Z]), -300) == ms(~U[2026-10-09 14:00:00Z])
      assert Rules.next_review(ms(~U[2026-10-09 15:00:00Z]), -300) == ms(~U[2026-10-10 14:00:00Z])
      # 02:00 UTC is still the day before at -300.
      assert Rules.next_review(ms(~U[2026-10-09 02:00:00Z]), -300) == ms(~U[2026-10-09 14:00:00Z])
    end

    test "at +330 (09:00 local is 03:30 UTC)" do
      assert Rules.next_review(ms(~U[2026-10-09 03:00:00Z]), 330) == ms(~U[2026-10-09 03:30:00Z])
      assert Rules.next_review(ms(~U[2026-10-09 04:00:00Z]), 330) == ms(~U[2026-10-10 03:30:00Z])
    end

    test "an offset that puts 09:00 local on the previous UTC day" do
      # At +840, 09:00 local is 19:00 UTC the day before.
      assert Rules.next_review(ms(~U[2026-10-09 18:00:00Z]), 840) == ms(~U[2026-10-09 19:00:00Z])
      assert Rules.next_review(ms(~U[2026-10-09 20:00:00Z]), 840) == ms(~U[2026-10-10 19:00:00Z])
    end
  end

  describe "next_firing/3" do
    test "on time, the next slot" do
      at = ms(@now)
      assert Rules.next_firing(at, 3 * @hour, at) == at + 3 * @hour
      assert Rules.next_firing(at, 3 * @hour, at + 1_000) == at + 3 * @hour
    end

    test "after a long gap, one firing then the grid" do
      at = ms(@now)
      # Down for a day and a half: fires once now, then the next slot on the grid.
      now = at + @day + 12 * @hour + 5_000
      next = Rules.next_firing(at, 3 * @hour, now)
      assert next == at + 13 * 3 * @hour
      assert next > now and next - now <= 3 * @hour
    end
  end

  describe "firing/1" do
    test "off, then no consent, then queued, in that order" do
      assert Rules.firing(%{on?: false, allowed?: false, queued?: true}) == {:skip, "off"}

      assert Rules.firing(%{on?: true, allowed?: false, queued?: true}) ==
               {:skip, "skipped_consent"}

      assert Rules.firing(%{on?: true, allowed?: true, queued?: true}) ==
               {:skip, "skipped_queued"}

      assert Rules.firing(%{on?: true, allowed?: true, queued?: false}) == :go
    end
  end

  describe "digest/3" do
    test "an unread thread's \"finished\" item is new" do
      result = Rules.digest([finished("i1", "c_1")], [board_entry("c_1", :unread)], @places)

      assert [%{kind: "finished", new?: true, thread_id: "c_1", project: "Garden"} = row] =
               result.new

      assert row.title == "Thread c_1"
      assert result.smaller == [] and result.gone == []
    end

    test "a seen, resolved or written-to-again thread's is smaller" do
      board = [
        board_entry("c_1", :idle),
        board_entry("c_2", :idle, @garden, resolved_at: ago(1)),
        board_entry("c_3", :running)
      ]

      items = [finished("i1", "c_1"), finished("i2", "c_2"), finished("i3", "c_3")]
      result = Rules.digest(items, board, @places)

      assert result.new == []
      assert result.smaller |> Enum.map(& &1.thread_id) |> Enum.sort() == ["c_1", "c_2", "c_3"]
      assert Enum.all?(result.smaller, &(not &1.new?))
    end

    test "a gone thread's item is in gone" do
      result = Rules.digest([finished("i1", "c_gone")], [], @places)
      assert result.gone == ["i1"]
      assert result.new == [] and result.smaller == []
    end

    test "one \"finished\" item per thread, the newest" do
      items = [finished("i1", "c_1", ago(3)), finished("i2", "c_1", ago(2))]
      items = [Map.put(hd(items), :note, "old") | [Map.put(List.last(items), :note, "new")]]
      result = Rules.digest(items, [board_entry("c_1", :unread)], @places)

      assert [%{note: "new"}] = result.new
      assert result.gone == []
    end

    test "a schedule item is new while the schedule exists, gone after" do
      item =
        item("i1", "schedule_stopped", schedule_id: "sc_9", project_id: "p_garden", note: "boom")

      assert [
               %{
                 schedule_id: "sc_9",
                 prompt: "check the gutters",
                 reason: "boom",
                 project: "Garden"
               }
             ] =
               Rules.digest([item], [], @places).new

      assert Rules.digest([item], [], %{@places | prompts: %{}}).gone == ["i1"]
    end

    test "Blip's own schedule has no project" do
      item = item("i1", "schedule_stopped", schedule_id: "sc_9", note: "boom")
      assert [%{project: nil, new?: true}] = Rules.digest([item], [], @places).new
    end

    test "\"file_written\" folds per project and file, the newest writer" do
      items = [
        item("i1", "file_written",
          project_id: "p_garden",
          name: "notes.md",
          writer: "user",
          inserted_at: ago(3)
        ),
        item("i2", "file_written",
          project_id: "p_garden",
          name: "notes.md",
          writer: "c_1",
          inserted_at: ago(2)
        ),
        item("i3", "file_written",
          project_id: "p_garden",
          name: "plan.md",
          writer: "user",
          note: "deleted"
        ),
        item("i4", "file_written", project_id: "p_house", name: "notes.md", writer: "user")
      ]

      result = Rules.digest(items, [board_entry("c_1", :idle)], @places)

      assert [
               %{project: "Garden", name: "notes.md", writer: "c_1", writer_title: "Thread c_1"},
               %{project: "Garden", name: "plan.md", deleted?: true},
               %{project: "House", name: "notes.md", writer: "user", writer_title: nil}
             ] = result.smaller

      assert result.new == [] and result.gone == []
    end

    test "a file in a project that is gone is dropped" do
      item = item("i1", "file_written", project_id: "p_gone", name: "a.md", writer: "user")
      assert Rules.digest([item], [], @places).gone == ["i1"]
    end

    test "\"resolved\" is gone after a reopen" do
      item = item("i1", "resolved", thread_id: "c_1", project_id: "p_garden")
      resolved = board_entry("c_1", :idle, @garden, resolved_at: ago(1))

      assert [%{kind: "resolved"}] = Rules.digest([item], [resolved], @places).smaller
      assert Rules.digest([item], [board_entry("c_1", :idle)], @places).gone == ["i1"]
    end

    test "projects, Purpose edits and started threads ride along, gone with their subject" do
      items = [
        item("i1", "project_created", project_id: "p_house"),
        item("i2", "purpose_changed", project_id: "p_garden", inserted_at: ago(3)),
        item("i3", "purpose_changed", project_id: "p_garden", inserted_at: ago(2)),
        item("i4", "thread_started", thread_id: "c_1", project_id: "p_garden"),
        item("i5", "project_created", project_id: "p_gone"),
        item("i6", "thread_started", thread_id: "c_gone", project_id: "p_garden"),
        item("i7", "something_else", project_id: "p_garden")
      ]

      result = Rules.digest(items, [board_entry("c_1", :running)], @places)

      assert Enum.map(result.smaller, &{&1.kind, &1.project}) == [
               {"purpose_changed", "Garden"},
               {"thread_started", "Garden"},
               {"project_created", "House"}
             ]

      assert Enum.sort(result.gone) == ["i5", "i6", "i7"]
    end

    test "only smaller items give no new rows" do
      item = item("i1", "project_created", project_id: "p_garden")
      result = Rules.digest([item], [], @places)
      assert result.new == [] and result.more_new == 0
      assert length(result.smaller) == 1
    end

    test "ordered by project name, then time" do
      board = [
        board_entry("c_1", :unread, @house),
        board_entry("c_2", :unread),
        board_entry("c_3", :unread)
      ]

      items = [
        finished("i1", "c_1", ago(5)),
        finished("i2", "c_2", ago(1)),
        finished("i3", "c_3", ago(3))
      ]

      assert Enum.map(Rules.digest(items, board, @places).new, & &1.thread_id) == [
               "c_3",
               "c_2",
               "c_1"
             ]
    end

    test "the 20 and 15 cuts, and both more counts" do
      board = for n <- 1..23, do: board_entry("c_#{n}", :unread)
      new = for n <- 1..23, do: finished("n#{n}", "c_#{n}")

      smaller =
        for n <- 1..18,
            do:
              item("s#{n}", "file_written",
                project_id: "p_garden",
                name: "f#{n}.md",
                writer: "user"
              )

      result = Rules.digest(new ++ smaller, board, @places)

      assert length(result.new) == 20 and result.more_new == 3
      assert length(result.smaller) == 15 and result.more_smaller == 3
    end

    test "the snapshot counts" do
      board = [
        board_entry("c_1", :running),
        board_entry("c_2", :asking),
        board_entry("c_3", :waiting),
        board_entry("c_4", :failed),
        board_entry("c_5", :failed),
        board_entry("c_6", :idle)
      ]

      assert Rules.digest([], board, @places).snapshot == %{running: 2, waiting: 1, failed: 2}
    end
  end

  describe "review/3" do
    @opts %{quiet_after: 72 * 3600, again_after: 7 * 86_400}

    defp touched(id, state, hours, fields \\ []) do
      board_entry(
        id,
        state,
        @garden,
        Keyword.merge([active_at: ago(hours), last_run_ended_at: ago(hours)], fields)
      )
    end

    defp ids(board),
      do: board |> Rules.review(@now, @opts) |> Map.fetch!(:rows) |> Enum.map(& &1.thread_id)

    test "quiet, failed and waiting are in; running, asking, unread and idle are out" do
      board =
        for state <- [:quiet, :failed, :waiting, :running, :asking, :unread, :idle],
            do: touched(Atom.to_string(state), state, 100)

      assert Enum.sort(ids(board)) == ["failed", "quiet", "waiting"]
    end

    test "the 72-hour edge" do
      exactly = DateTime.add(@now, -72 * 3600, :second)
      just_past = DateTime.add(exactly, -1, :second)

      assert ids([
               board_entry("c_1", :quiet, @garden, active_at: exactly, last_run_ended_at: exactly)
             ]) ==
               []

      assert ids([
               board_entry("c_1", :quiet, @garden,
                 active_at: just_past,
                 last_run_ended_at: just_past
               )
             ]) ==
               ["c_1"]
    end

    test "a question's passed_at is the last touch" do
      waiting = touched("c_1", :waiting, 100)

      question = %{
        status: "with_owner",
        passed_at: ago(10),
        question: "Which white?",
        wording: nil
      }

      waiting = %{waiting | questions: [question]}

      assert Rules.last_touch(waiting) == ago(10)
      assert ids([waiting]) == []
      assert ids([%{waiting | questions: [%{question | passed_at: ago(80)}]}]) == ["c_1"]
    end

    test "reviewed_at: nil, before the touch, after it, and older than again_after" do
      assert ids([touched("c_1", :quiet, 100, reviewed_at: nil)]) == ["c_1"]
      assert ids([touched("c_1", :quiet, 100, reviewed_at: ago(110))]) == ["c_1"]
      assert ids([touched("c_1", :quiet, 300, reviewed_at: ago(24))]) == []
      assert ids([touched("c_1", :quiet, 300, reviewed_at: ago(7 * 24 + 1))]) == ["c_1"]
    end

    test "the oldest touch first, cut at 10 with how many more" do
      board = for n <- 1..12, do: touched("c_#{n}", :quiet, 80 + n)
      review = Rules.review(board, @now, @opts)

      assert length(review.rows) == 10 and review.more == 2
      assert hd(review.rows).thread_id == "c_12"
      assert review.quiet_after == 72 * 3600
    end

    test "a row's detail: Blip's wording of the open question, else the run's note" do
      question = %{
        status: "with_owner",
        passed_at: ago(80),
        question: "Which white?",
        wording: "Chalk or Linen?"
      }

      waiting = %{touched("c_1", :waiting, 100) | questions: [question]}

      failed =
        touched("c_2", :failed, 90,
          last_run_note: "the ladder is offline",
          last_run_status: "failed"
        )

      assert [%{detail: "the ladder is offline"}, %{detail: "Chalk or Linen?", state: :waiting}] =
               Rules.review([waiting, failed], @now, @opts).rows

      unworded = %{waiting | questions: [%{question | wording: nil}]}
      assert [%{detail: "Which white?"}] = Rules.review([unworded], @now, @opts).rows
    end
  end

  test "every_options/0" do
    assert Rules.every_options() == [60, 180, 360]
  end
end
