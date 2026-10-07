defmodule PhotonWeb.ActivityLiveTest do
  @moduledoc """
  The activity page (section 10.7 of
  `docs/plans/step-4-blip-as-coordinator.md`): Blip's actions newest
  first with who asked and where, the filters, Show older, the empty
  states, and a row recorded while the page is open going on top.

  The rows are written straight into the log (as `Photon.Activity`'s
  hooks would), and the threads they name straight into their table:
  the page only reads them. `test/boundary/activity_test.exs` covers how
  the hooks record rows, and `test/web/activity_text_test.exs` the words.
  """

  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Photon.Eventually, only: [eventually: 1]

  alias Photon.{Activity, Durable, Projects, Repo}
  alias Photon.Activity.Action
  alias Photon.Durable.Entry
  alias Photon.Schedules.Schedule
  alias Photon.Threads.Thread

  @moduletag :durable

  @start ~U[2026-10-06 12:00:00.000000Z]

  setup do
    {:ok, garden} =
      Projects.create(%{"purpose" => "Keep the vegetable beds watered.", "name" => "Garden"})

    pump =
      Repo.insert!(%Thread{
        id: "c_pump",
        project_id: garden.id,
        title: "Fix the pump",
        active_at: @start
      })

    :ok = Activity.subscribe()
    %{garden: garden, pump: pump}
  end

  defp activity(conn) do
    {:ok, view, _html} = live(conn, ~p"/activity")
    view
  end

  # A row of the log, `seconds` after the start.
  defp row!(id, seconds, fields \\ []) do
    Repo.insert!(
      struct!(
        %Action{
          id: id,
          kind: "call",
          tool: "shell",
          summary: "Ran `ls` on mm1",
          status: "ok",
          changes: true,
          origin: "owner",
          entry_id: "e_" <> id,
          inserted_at: DateTime.add(@start, seconds, :second)
        },
        fields
      )
    )
  end

  defp shown(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#activity-list > li")
    |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))
  end

  test "rows newest first, with who asked, what Blip did and where", %{
    conn: conn,
    garden: garden
  } do
    Repo.insert!(%Schedule{
      id: "sc_disks",
      prompt: "check my disks",
      first_at: @start,
      version: 1,
      created_by: "owner"
    })

    row!("a_1", 1, tool: "list_projects", summary: "Listed projects", changes: false)

    row!("a_2", 2,
      tool: "message_thread",
      summary: ~s(Messaged "Fix the pump"),
      origin: "thread",
      origin_id: "c_pump",
      project_id: garden.id,
      thread_id: "c_pump"
    )

    row!("a_3", 3,
      origin: "schedule",
      origin_id: "sc_disks",
      status: "error",
      summary: "Ran `df -h` on mm1: failed"
    )

    row!("a_4", 4,
      kind: "message",
      tool: nil,
      summary: "Told you: The pump is fixed.",
      changes: false,
      origin: "follow_up",
      origin_id: "c_pump"
    )

    row!("a_5", 5, origin: "thread", origin_id: "c_gone")

    view = activity(conn)
    refute has_element?(view, "#no-activity")
    refute has_element?(view, "#activity-more")
    assert shown(view) == ~w(activity-a_5 activity-a_4 activity-a_3 activity-a_2 activity-a_1)

    assert has_element?(view, "#activity-a_1-summary", "Listed projects")
    assert has_element?(view, "#activity-a_1-origin", "You")
    refute has_element?(view, "#activity-a_1-target")
    assert has_element?(view, "#activity-a_1-at")

    # A thread who asked, linked; where the call acted, linked: the
    # project, since the thread it acted on is the one who asked.
    assert has_element?(
             view,
             "#activity-a_2-origin-thread[href='/projects/garden/threads/c_pump']",
             "Fix the pump"
           )

    assert has_element?(view, "#activity-a_2-project[href='/projects/garden']", "Garden")
    refute has_element?(view, "#activity-a_2-thread")

    # A schedule by its prompt; a failed call marked.
    assert has_element?(view, "#activity-a_3-origin", "Schedule: check my disks")
    assert has_element?(view, "#activity-a_3[data-status=failed]")
    assert has_element?(view, "#activity-a_3-mark[title=Failed]")

    # Something Blip told the owner, on a follow-up about a thread.
    assert has_element?(view, "#activity-a_4-summary", "Told you: The pump is fixed.")
    assert has_element?(view, "#activity-a_4-origin", "Blip's follow-up on")
    assert has_element?(view, "#activity-a_4-origin-thread", "Fix the pump")

    # A thread that is gone reads as plain text.
    assert has_element?(view, "#activity-a_5-origin", "A thread")
    refute has_element?(view, "#activity-a_5-origin a")
  end

  test "a thread named or renamed since shows its new title, once per row", %{
    conn: conn,
    garden: garden
  } do
    row!("a_1", 1,
      tool: "start_thread",
      summary: ~s(Started "fix the pump please" in garden),
      project_id: garden.id,
      thread_id: "c_pump"
    )

    row!("a_2", 2,
      tool: "answer_question",
      summary: "Answered: staging",
      origin: "thread",
      origin_id: "c_pump",
      project_id: garden.id,
      thread_id: "c_pump"
    )

    view = activity(conn)
    assert has_element?(view, "#activity-a_1-summary", ~s(Started "Fix the pump" in garden))
    assert has_element?(view, "#activity-a_1-thread", "Fix the pump")

    # Asked by the thread it answered: named once, as the asker.
    assert has_element?(view, "#activity-a_2-origin-thread", "Fix the pump")
    assert has_element?(view, "#activity-a_2-project", "Garden")
    refute has_element?(view, "#activity-a_2-thread")

    {:ok, _thread} = Photon.Threads.rename("c_pump", "Pump repair")

    assert eventually(fn ->
             has_element?(view, "#activity-a_1-summary", ~s(Started "Pump repair" in garden))
           end)

    assert has_element?(view, "#activity-a_1-thread", "Pump repair")
    assert has_element?(view, "#activity-a_2-origin-thread", "Pump repair")
    assert shown(view) == ~w(activity-a_2 activity-a_1)
  end

  test "the filters narrow by who asked and to changes", %{conn: conn} do
    row!("a_1", 1, changes: false, tool: "list_projects", summary: "Listed projects")
    row!("a_2", 2, origin: "thread", origin_id: "c_pump")
    row!("a_3", 3, origin: "schedule", origin_id: "sc_1", changes: false)
    row!("a_4", 4)

    view = activity(conn)
    assert has_element?(view, "#activity-origin")
    assert has_element?(view, "#activity-changes")

    view
    |> form("#activity-filter")
    |> render_change(%{filter: %{origin: "thread", changes: "false"}})

    assert shown(view) == ~w(activity-a_2)

    view
    |> form("#activity-filter")
    |> render_change(%{filter: %{origin: "", changes: "true"}})

    assert shown(view) == ~w(activity-a_4 activity-a_2)
    assert has_element?(view, "#activity-changes[checked]")

    view
    |> form("#activity-filter")
    |> render_change(%{filter: %{origin: "follow_up", changes: "false"}})

    assert shown(view) == []
    assert has_element?(view, "#no-activity", "Nothing matches.")

    view
    |> form("#activity-filter")
    |> render_change(%{filter: %{origin: "", changes: "false"}})

    assert shown(view) == ~w(activity-a_4 activity-a_3 activity-a_2 activity-a_1)
    refute has_element?(view, "#no-activity")
  end

  test "Show older appends the next rows past the last one shown", %{conn: conn} do
    for n <- 1..55, do: row!("a_#{String.pad_leading("#{n}", 2, "0")}", n)

    view = activity(conn)
    assert length(shown(view)) == 50
    assert hd(shown(view)) == "activity-a_55"
    assert List.last(shown(view)) == "activity-a_06"

    view |> element("#activity-more") |> render_click()

    rows = shown(view)
    assert length(rows) == 55

    assert Enum.slice(rows, 50..54) ==
             ~w(activity-a_05 activity-a_04 activity-a_03 activity-a_02 activity-a_01)

    refute has_element?(view, "#activity-more")
  end

  test "Show older keeps to the filter", %{conn: conn} do
    for n <- 10..64, do: row!("a_#{n}", n, origin: "schedule")
    row!("a_01", 1)

    view = activity(conn)

    view
    |> form("#activity-filter")
    |> render_change(%{filter: %{origin: "schedule", changes: "false"}})

    view |> element("#activity-more") |> render_click()
    rows = shown(view)
    assert length(rows) == 55
    refute "activity-a_01" in rows
  end

  test "empty, it says what will show here", %{conn: conn} do
    view = activity(conn)
    assert has_element?(view, "#no-activity", "Nothing yet. When Blip runs a command")
    assert shown(view) == []
  end

  test "a row recorded from another process goes on top, if it passes the filter", %{
    conn: conn
  } do
    row!("a_1", 1)
    view = activity(conn)

    message = %{
      kind: "message",
      entry_id: "e_told",
      text: "The pump is fixed.\nIt was the float switch.",
      origin: %{by: "follow_up", id: "c_pump"}
    }

    told = record!(message)
    assert shown(view) == ["activity-#{told}", "activity-a_1"]
    assert has_element?(view, "#activity-#{told}-summary", "Told you: The pump is fixed.")
    assert has_element?(view, "#activity-#{told}-origin-thread", "Fix the pump")

    # With a filter on, one that doesn't pass stays off the page.
    view
    |> form("#activity-filter")
    |> render_change(%{filter: %{origin: "owner", changes: "false"}})

    task = %Durable.TaskRecord{
      input: %{"call" => %{"name" => "list_machines", "arguments" => "{}"}}
    }

    call = %{
      kind: "call",
      task: task,
      entry: %Entry{id: "e_machines", data: %{"status" => "ok", "details" => %{}}},
      origin: %{by: "schedule", id: "sc_1"}
    }

    _hidden = record!(call)
    assert shown(view) == ["activity-a_1"]

    mine =
      record!(%{call | entry: %Entry{call.entry | id: "e_mine"}, origin: %{by: "owner", id: nil}})

    assert shown(view) == ["activity-#{mine}", "activity-a_1"]
    assert has_element?(view, "#activity-#{mine}-summary", "Checked your machines")
  end

  test "the first row recorded takes the empty state's place", %{conn: conn} do
    view = activity(conn)
    assert has_element?(view, "#no-activity")

    id =
      record!(%{
        kind: "message",
        entry_id: "e_1",
        text: "Done.",
        origin: %{by: "schedule", id: nil}
      })

    assert shown(view) == ["activity-#{id}"]
    refute has_element?(view, "#no-activity")
  end

  # Records a row from another process, as Blip's hooks do inside their
  # commits; returns its ID. The announcement reaches the page's mailbox
  # before the commit returns, so the next render has handled it.
  defp record!(record) do
    :ok =
      fn -> Durable.commit(&Activity.record_tx(&1, record)) end
      |> Task.async()
      |> Task.await()

    assert_receive {:activity_added, id}
    id
  end
end
