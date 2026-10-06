defmodule PhotonWeb.OverviewLiveTest do
  @moduledoc """
  The home page: machines and schedules, kept current as they change.
  """

  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Photon.{Assistant, Durable, Machines, NodeKeys}

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
