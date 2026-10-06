defmodule PhotonWeb.OverviewLiveTest do
  @moduledoc """
  The home page: machines and schedules, kept current as they change.
  """

  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Photon.{Assistant, Durable, Machines, NodeKeys, Projects, Schedules}
  alias Photon.Durable.Tx
  alias Photon.Schedules.Routine

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
    assert has_element?(view, "#no-schedules", "Project schedules are on each project's page.")

    schedule =
      blip_schedule!(
        %{"prompt" => "check disks", "at" => "2035-01-01T00:00:00Z", "every_minutes" => 60},
        "schedule:t_disks"
      )

    assert has_element?(view, "#schedule-#{schedule.id}", "check disks")
    assert has_element?(view, "#schedule-#{schedule.id}-when", "Every hour · next")

    assert has_element?(
             view,
             ~s(#schedule-#{schedule.id}-when time[datetime="2035-01-01T00:00:00Z"]),
             "Jan 1, 00:00 UTC"
           )

    refute has_element?(view, "#schedule-#{schedule.id}-last")

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
        "at" => "2035-01-01T00:00:00Z",
        "repeat" => "once",
        "target" => "new_thread"
      })

    mine = blip_schedule!(%{"prompt" => "check disks", "in_minutes" => 60}, "schedule:t_mine")

    assert has_element?(view, "#schedule-#{mine.id}-when", "Once ·")
    assert has_element?(view, "#schedule-#{mine.id}-when time[datetime]")
    refute has_element?(view, "#schedule-#{theirs.id}")
  end

  test "keeps a schedule that stopped after an error in sight, with why, until it's cancelled",
       %{view: view} do
    schedule =
      blip_schedule!(
        %{"prompt" => "check disks", "at" => "2035-01-01T00:00:00Z", "every_minutes" => 1440},
        "schedule:t_stopped"
      )

    task = Durable.task(schedule.task_id)

    :ok =
      Durable.commit(fn tx ->
        _failed = Tx.finish(tx, task, "failed", %{"status" => "failed", "reason" => "boom"})
        Routine.on_fail(task, "boom", tx)
      end)

    _ = render(view)
    assert has_element?(view, ~s(#schedule-#{schedule.id}-when[data-state="stopped"]))

    assert has_element?(
             view,
             "#schedule-#{schedule.id}-when",
             "Stopped after an error: boom. Cancel it, and ask Blip to schedule it again."
           )

    view |> element("#schedule-#{schedule.id}-cancel") |> render_click()
    assert Schedules.get(schedule.id) == nil
    refute has_element?(view, "#schedule-#{schedule.id}")
  end

  test "says when a schedule last ran and what it did", %{view: view} do
    schedule =
      blip_schedule!(
        %{"prompt" => "check disks", "at" => "2035-01-01T00:00:00Z", "every_minutes" => 1440},
        "schedule:t_last"
      )

    {:ok, "sent"} = Schedules.run_now(schedule.id)
    %{schedule: %{last_run_at: ran_at}} = Schedules.get(schedule.id)
    _ = render(view)

    assert has_element?(view, "#schedule-#{schedule.id}-when", "Every day · next")
    assert has_element?(view, "#schedule-#{schedule.id}-last", "Last ran")
    assert has_element?(view, "#schedule-#{schedule.id}-last", ": sent")

    iso = ran_at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    assert has_element?(view, ~s(#schedule-#{schedule.id}-last time[datetime="#{iso}"]))
  end
end
