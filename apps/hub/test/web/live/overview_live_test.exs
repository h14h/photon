defmodule PhotonWeb.OverviewLiveTest do
  @moduledoc """
  The home page: machines, work running now and lately, and schedules,
  kept current as they change.
  """

  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Photon.Fixtures, only: [state_record: 1, state_record: 2]

  alias Photon.{Assistant, Durable, NodeSessions}

  @moduletag :durable

  setup %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    %{view: view}
  end

  test "without machines, says how to add one", %{view: view} do
    assert has_element?(view, "#no-machines")
    assert has_element?(view, "#overview-summary", "Add a machine")
    assert has_element?(view, "#running", "Nothing running")
    assert has_element?(view, "#recent", "Nothing has finished yet")
    assert has_element?(view, "#nav-overview")
    assert page_title(view) =~ "Overview"
  end

  test "shows each machine and its work, running and finished", %{view: view} do
    {:ok, backup, _input} = NodeSessions.start("box", "backup", title: "Nightly backup")

    {:ok, check, _input} =
      NodeSessions.start("box", "check disks", origin: "assistant", title: "Check disks")

    :ok = NodeSessions.ingest(backup.id, "box", 0, state_record("running"))
    :ok = NodeSessions.ingest(check.id, "box", 0, state_record("running"))
    :ok = NodeSessions.ingest(check.id, "box", 1, state_record("idle", %{"failure" => "no disk"}))

    assert has_element?(view, "#machine-box", "offline")
    assert has_element?(view, "#overview-summary", "0 of 1 machine online. 1 thing running.")
    assert has_element?(view, "#running #work-#{backup.id}", "by you")
    assert has_element?(view, "#recent #work-#{check.id}", "by Blip")
    assert has_element?(view, "#recent #work-#{check.id} [title=Failed]")
  end

  test "lists schedules, which can be cancelled", %{view: view} do
    assert has_element?(view, "#schedules", "None yet")

    routine =
      Durable.create_task(%{
        kind: "routine",
        conversation_id: Assistant.conversation_id(),
        background: true,
        input: %{
          "prompt" => "check disks",
          "first_at" => 4_102_444_800_000,
          "every_ms" => 3_600_000
        }
      })

    _ = render(view)
    assert has_element?(view, "#schedule-#{routine.id}", "check disks")
    assert has_element?(view, "#schedule-#{routine.id}", "Every 1h")

    view |> element("#schedule-#{routine.id} button") |> render_click()
    assert Durable.task(routine.id).abort_requested
  end
end
