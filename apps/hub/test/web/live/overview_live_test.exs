defmodule PhotonWeb.OverviewLiveTest do
  @moduledoc """
  The home page: machines and schedules, kept current as they change.
  """

  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Photon.{Assistant, Durable, Machines, NodeKeys, Projects, Schedules}

  @moduletag :durable

  setup %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    %{view: view}
  end

  test "without machines, says how to add one", %{view: view} do
    assert has_element?(view, "#no-machines")
    assert has_element?(view, "#overview-summary", "Add a machine")
    refute has_element?(view, "#work-hint")
    assert has_element?(view, "#nav-home[aria-current=page]")
    assert page_title(view) =~ "Overview"
  end

  test "shows connected machines and known offline ones, and points at Blip and projects", %{
    view: view
  } do
    {:ok, _key} = NodeKeys.issue("nas")
    :ok = Machines.register("box", %{"hostname" => "box.lan", "platform" => "linux"})
    Machines.broadcast()
    _ = render(view)

    assert has_element?(view, "#machine-box", "online")
    assert has_element?(view, "#machine-box", "box.lan · linux")
    assert has_element?(view, "#machine-nas", "offline")
    assert has_element?(view, "#overview-summary", "1 of 2 machines online.")
    assert has_element?(view, "#work-hint", "Ask Blip")
    assert has_element?(view, ~s(#work-hint-new-project[href="/projects/new"]), "start a project")
  end

  # One of Blip's schedules, as its `schedule` tool makes it.
  defp blip_schedule!(args, request_id) do
    now = System.system_time(:millisecond)

    {:ok, schedule} =
      Durable.commit(
        &Schedules.blip_schedule_tx(&1, Assistant.conversation_id(), args, request_id, now)
      )

    schedule
  end

  test "lists Blip's schedules, which can be cancelled", %{view: view} do
    assert has_element?(view, "#no-schedules", "None yet")

    schedule =
      blip_schedule!(
        %{"prompt" => "check disks", "at" => "2100-01-01T00:00:00Z", "every_minutes" => 60},
        "schedule:t_disks"
      )

    assert has_element?(view, "#schedule-#{schedule.id}", "check disks")
    assert has_element?(view, "#schedule-#{schedule.id}", "Every 1h · next Jan 1, 00:00 UTC")

    view |> element("#schedule-#{schedule.id} button") |> render_click()
    assert Schedules.get(schedule.id) == nil
    refute has_element?(view, "#schedule-#{schedule.id}")
  end

  test "leaves out a project's schedules, which are on its page", %{view: view} do
    {:ok, project} =
      Projects.create(%{"purpose" => "Keep the garden watered.", "name" => "Garden"})

    {:ok, theirs} =
      Schedules.create({:project, project.id}, %{
        "prompt" => "Check the backups",
        "at" => "2100-01-01T00:00:00Z",
        "repeat" => "once",
        "target" => "new_thread"
      })

    mine = blip_schedule!(%{"prompt" => "check disks", "in_minutes" => 60}, "schedule:t_mine")

    assert has_element?(view, "#schedule-#{mine.id}", "Once, ")
    refute has_element?(view, "#schedule-#{theirs.id}")
  end
end
