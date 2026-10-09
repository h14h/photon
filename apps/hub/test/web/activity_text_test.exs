defmodule PhotonWeb.ActivityTextTest do
  @moduledoc """
  The activity page's words and rows: the filter, the empty state, what a
  page of rows names, and who asked and where, linked only when the page
  found what a row names.
  """

  use ExUnit.Case, async: true

  alias Photon.Activity.Action
  alias PhotonWeb.ActivityText

  @at ~U[2026-10-07 09:00:00.000000Z]

  defp action(fields) do
    struct!(
      %Action{
        id: "a_1",
        kind: "call",
        tool: "shell",
        summary: "Ran `ls` on mm1",
        status: "ok",
        changes: true,
        origin: "owner",
        entry_id: "e_1",
        inserted_at: @at
      },
      fields
    )
  end

  @lookup %{
    places: %{
      "c_pump" => %{title: "Fix the pump", project_id: "p_garden"},
      "c_lost" => %{title: "In a gone project", project_id: "p_gone"}
    },
    prompts: %{"sc_disks" => "check my disks"},
    projects: %{"p_garden" => %{name: "Garden", slug: "garden"}}
  }

  @pump %{id: "c_pump", title: "Fix the pump", slug: "garden"}

  describe "the filter" do
    test "options: everyone, then the four kinds of asker the owner can pick" do
      assert ActivityText.origin_options() == [
               {"Everyone", ""},
               {"You", "owner"},
               {"Threads", "thread"},
               {"Schedules", "schedule"},
               {"Blip's follow-ups", "follow_up"}
             ]
    end

    test "reads the form's params; anything it doesn't know means everyone, every row" do
      assert ActivityText.filter(%{"origin" => "thread", "changes" => "true"}) ==
               %{origin: "thread", changes_only: true}

      assert ActivityText.filter(%{"origin" => "", "changes" => "false"}) == ActivityText.all()
      assert ActivityText.filter(%{"origin" => "comet", "changes" => "yes"}) == ActivityText.all()
      assert ActivityText.filter(%{}) == ActivityText.all()
      assert ActivityText.filter(nil) == ActivityText.all()
    end

    test "goes back into the form's params and into list/1's options" do
      filter = %{origin: "schedule", changes_only: true}
      assert ActivityText.params(filter) == %{"origin" => "schedule", "changes" => "true"}
      assert ActivityText.params(ActivityText.all()) == %{"origin" => "", "changes" => "false"}
      assert ActivityText.list_opts(filter) == [origin: "schedule", changes_only: true]
    end

    test "matches? a new row by who asked and whether it changes something" do
      read = action(origin: "thread", changes: false)

      assert ActivityText.matches?(read, ActivityText.all())
      assert ActivityText.matches?(read, %{origin: "thread", changes_only: false})
      refute ActivityText.matches?(read, %{origin: "owner", changes_only: false})
      refute ActivityText.matches?(read, %{origin: nil, changes_only: true})
      assert ActivityText.matches?(action(changes: true), %{origin: "owner", changes_only: true})
    end

    test "the empty state says what the page is for, or that nothing matches" do
      assert ActivityText.empty(ActivityText.all()) =~ "Nothing yet. When Blip runs a command"
      assert ActivityText.empty(%{origin: "owner", changes_only: false}) == "Nothing matches."
      assert ActivityText.empty(%{origin: nil, changes_only: true}) == "Nothing matches."
    end
  end

  test "wanted/1: the threads and schedules a page of rows names, once each" do
    actions = [
      action(origin: "thread", origin_id: "c_pump", thread_id: "c_beds"),
      action(origin: "follow_up", origin_id: "c_pump"),
      action(origin: "follow_up", origin_id: "sc_morning"),
      action(origin: "schedule", origin_id: "sc_disks"),
      action(origin: "schedule", origin_id: "sc_disks", thread_id: "c_pump"),
      action(origin: "owner"),
      # A follow-up on a digest or the daily review names no schedule.
      action(origin: "follow_up", origin_id: "digest"),
      action(origin: "follow_up", origin_id: "review")
    ]

    assert ActivityText.wanted(actions) == %{
             threads: ["c_pump", "c_beds"],
             schedules: ["sc_morning", "sc_disks"]
           }

    assert ActivityText.wanted([]) == %{threads: [], schedules: []}
  end

  describe "row/2" do
    test "carries what the row says, with its status" do
      row = ActivityText.row(action([]), @lookup)

      assert %{
               id: "a_1",
               kind: "call",
               tool: "shell",
               summary: "Ran `ls` on mm1",
               at: @at,
               status: :ok,
               project: nil,
               thread: nil
             } = row

      assert ActivityText.row(action(status: "error"), @lookup).status == :failed
      assert ActivityText.row(action(status: "aborted"), @lookup).status == :stopped
      assert ActivityText.row(action(status: "interrupted"), @lookup).status == :interrupted
    end

    test "who asked: the owner, a schedule, Blip" do
      assert ActivityText.row(action([]), @lookup).origin ==
               %{by: "owner", lead: "You", thread: nil}

      assert ActivityText.row(action(origin: "schedule", origin_id: "sc_disks"), @lookup).origin ==
               %{by: "schedule", lead: "Schedule: check my disks", thread: nil}

      assert ActivityText.row(action(origin: "schedule", origin_id: "sc_gone"), @lookup).origin ==
               %{by: "schedule", lead: "A schedule", thread: nil}

      assert ActivityText.row(action(origin: "unknown"), @lookup).origin ==
               %{by: "unknown", lead: "Blip", thread: nil}
    end

    test "a thread who asked is linked when the page found it and its project" do
      assert ActivityText.row(action(origin: "thread", origin_id: "c_pump"), @lookup).origin ==
               %{by: "thread", lead: "", thread: @pump}

      # Gone, or its project not found: plain text.
      assert ActivityText.row(action(origin: "thread", origin_id: "c_gone"), @lookup).origin ==
               %{by: "thread", lead: "A thread", thread: nil}

      assert ActivityText.row(action(origin: "thread", origin_id: "c_lost"), @lookup).origin ==
               %{by: "thread", lead: "In a gone project", thread: nil}

      # A run of two threads' questions names no single thread.
      assert ActivityText.row(action(origin: "thread", origin_id: nil), @lookup).origin ==
               %{by: "thread", lead: "A thread", thread: nil}
    end

    test "a follow-up links the thread it was about; one from Blip's own schedule names none" do
      assert ActivityText.row(action(origin: "follow_up", origin_id: "c_pump"), @lookup).origin ==
               %{by: "follow_up", lead: "Blip's follow-up on ", thread: @pump}

      assert ActivityText.row(action(origin: "follow_up", origin_id: "sc_disks"), @lookup).origin ==
               %{by: "follow_up", lead: "Blip's follow-up", thread: nil}

      assert ActivityText.row(action(origin: "follow_up", origin_id: "c_gone"), @lookup).origin ==
               %{by: "follow_up", lead: "Blip's follow-up", thread: nil}
    end

    test "where it acted: the project and thread it names, when the page found them" do
      both = ActivityText.row(action(project_id: "p_garden", thread_id: "c_pump"), @lookup)
      assert both.project == %{name: "Garden", slug: "garden"}
      assert both.thread == @pump

      only_project = ActivityText.row(action(project_id: "p_garden"), @lookup)

      assert {only_project.project, only_project.thread} ==
               {%{name: "Garden", slug: "garden"}, nil}

      # A thread without the row's project still names its own.
      only_thread = ActivityText.row(action(thread_id: "c_pump"), @lookup)
      assert only_thread.project == %{name: "Garden", slug: "garden"}

      gone = ActivityText.row(action(project_id: "p_gone", thread_id: "c_lost"), @lookup)
      assert {gone.project, gone.thread} == {nil, nil}
    end
  end

  describe "threads by their titles now" do
    test "a call on one thread says the thread's title now; a thread not found keeps the summary" do
      started =
        action(
          tool: "start_thread",
          summary: ~s(Started "fix the pump please" in garden),
          project_id: "p_garden",
          thread_id: "c_pump"
        )

      assert ActivityText.row(started, @lookup).summary == ~s(Started "Fix the pump" in garden)

      stopped =
        action(tool: "stop_thread", status: "aborted", summary: "x", thread_id: "c_pump")

      assert ActivityText.row(stopped, @lookup).summary == ~s(Stopped "Fix the pump": stopped)

      gone = action(tool: "read_thread", summary: ~s(Read "Old title"), thread_id: "c_gone")
      assert ActivityText.row(gone, @lookup).summary == ~s(Read "Old title")

      # Other calls keep what they said.
      answered =
        action(tool: "answer_question", summary: "Answered: staging", thread_id: "c_pump")

      assert ActivityText.row(answered, @lookup).summary == "Answered: staging"
    end

    test "a thread's question that led to a call on itself names the thread once" do
      row =
        ActivityText.row(
          action(
            tool: "answer_question",
            summary: "Answered: staging",
            origin: "thread",
            origin_id: "c_pump",
            project_id: "p_garden",
            thread_id: "c_pump"
          ),
          @lookup
        )

      assert row.origin == %{by: "thread", lead: "", thread: @pump}
      assert row.project == %{name: "Garden", slug: "garden"}
      assert row.thread == nil

      # A thread asking about another names both.
      other = %{
        @lookup
        | places: Map.put(@lookup.places, "c_beds", %{title: "Beds", project_id: "p_garden"})
      }

      row =
        ActivityText.row(
          action(origin: "thread", origin_id: "c_beds", thread_id: "c_pump"),
          other
        )

      assert row.thread == @pump
    end
  end

  test "status_text/1 names a mark for failures and stops only" do
    assert ActivityText.status_text(:failed) == "Failed"
    assert ActivityText.status_text(:stopped) == "Stopped"
    assert ActivityText.status_text(:interrupted) == "Cut short by a restart"
    assert ActivityText.status_text(:ok) == nil
  end
end
