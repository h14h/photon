defmodule PhotonWeb.ScheduleLiveTest do
  @moduledoc """
  A project's schedule page: the form that makes and edits one, its next
  and last run, Run now and Delete, the stale-save banner, and what the
  page does when the schedule changes or fires elsewhere.

  The form's time is a hidden field the browser's hook fills in; the
  tests set it directly, as an extra value on the submit. Threads run on
  the scripted model, and every test leaves them idle. Writes from the
  test process are other processes' writes as far as the page is
  concerned: the Store broadcasts inside the commit's call, so the page
  has the announcement queued before the test's next render.
  """

  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Photon.ConversationHelpers
  import Photon.ProjectHelpers

  alias Photon.{Durable, Projects, Schedules, Threads}
  alias Photon.Durable.{Scheduler, TaskRecord}
  alias Photon.Schedules.Schedule

  @moduletag :durable

  setup do
    %{project: garden!()}
  end

  defp new_page(conn, query \\ ""), do: live(conn, "/projects/garden/schedules/new" <> query)

  defp edit_page(conn, schedule), do: live(conn, ~p"/projects/garden/schedules/#{schedule.id}")

  # Submits the form with `params` and the hidden time `at`.
  defp submit(view, params, at) do
    view
    |> form("#schedule-form", schedule: params)
    |> render_submit(%{schedule: %{at: at}})
  end

  defp field(view, selector), do: view |> element(selector) |> render()

  # The element's text with its whitespace collapsed.
  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  describe "a new schedule" do
    test "the form starts at the next whole hour, once, in a new thread", %{conn: conn} do
      {:ok, view, _html} = new_page(conn)

      assert field(view, "#schedule-heading") =~ "New schedule"
      assert has_element?(view, "#schedule-form #schedule-prompt")
      assert has_element?(view, "#schedule-form #schedule-at-local[type=datetime-local]")
      assert has_element?(view, "#schedule-form #schedule-repeat-once[checked]")
      assert has_element?(view, ~s(#schedule-target option[value="new_thread"][selected]))
      assert has_element?(view, ~s(#schedule-form[data-dirty="false"]))
      refute has_element?(view, "#schedule-status")
      refute has_element?(view, "#schedule-delete")

      [at] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#schedule-at")
        |> LazyHTML.attribute("value")

      {:ok, at, 0} = DateTime.from_iso8601(at)
      assert at.minute == 0 and at.second == 0
      assert DateTime.diff(at, DateTime.utc_now()) in 0..3_600
    end

    test "a new thread each time, once, saves and returns to the project", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = new_page(conn)
      first = at(:timer.hours(2))

      {:ok, page, html} =
        view
        |> submit(%{prompt: "Check the backups", repeat: "once", target: "new_thread"}, first)
        |> follow_redirect(conn, ~p"/projects/garden")

      assert html =~ "Schedule saved."

      assert [%{schedule: schedule, state: :waiting}] = Schedules.list({:project, project.id})
      assert %Schedule{prompt: "Check the backups", every_minutes: nil} = schedule
      assert %Schedule{conversation_id: nil, created_by: "owner"} = schedule
      assert DateTime.to_unix(schedule.first_at) == first |> iso_seconds()
      assert has_element?(page, "#schedule-#{schedule.id}")
    end

    test "a thread, every 2 hours, saves on that thread", %{conn: conn, project: project} do
      thread = idle_thread!(project, "Fix the pump").id
      {:ok, view, _html} = new_page(conn)
      assert has_element?(view, ~s(#schedule-target option[value="#{thread}"]), "Fix the pump")

      view |> form("#schedule-form", schedule: %{repeat: "every"}) |> render_change()
      assert has_element?(view, "#schedule-repeat-field", "Repeats on a fixed interval")

      {:ok, _page, _html} =
        view
        |> submit(
          %{prompt: "Water the beds", repeat: "every", every: "2", unit: "hours", target: thread},
          at(:timer.hours(1))
        )
        |> follow_redirect(conn, ~p"/projects/garden")

      assert [%{schedule: %Schedule{every_minutes: 120, conversation_id: ^thread}}] =
               Schedules.list({:project, project.id})
    end

    test "errors show under their fields and keep what was typed", %{
      conn: conn,
      project: project
    } do
      {:ok, house} = Projects.create(%{"name" => "House", "purpose" => "Fix the roof."})
      elsewhere = idle_thread!(house, "Fix the roof").id
      {:ok, view, _html} = new_page(conn)

      submit(
        view,
        %{prompt: "  ", repeat: "every", every: "2", unit: "minutes"},
        at(:timer.hours(1))
      )

      assert has_element?(
               view,
               "#schedule-prompt-field",
               "Say what this schedule should ask for."
             )

      assert has_element?(view, "#schedule-repeat-field", "Repeat no more often than every 5")

      view
      |> form("#schedule-form", schedule: %{prompt: "Check the backups", repeat: "once"})
      |> render_submit(%{schedule: %{at: at(-:timer.minutes(5)), target: elsewhere}})

      assert has_element?(view, "#schedule-at-field", "That time has passed.")
      assert has_element?(view, "#schedule-target-field", "Pick one of this project's threads")
      assert has_element?(view, "#schedule-at-local[data-invalid=true]")
      assert field(view, "#schedule-prompt") =~ "Check the backups"
      refute has_element?(view, "#schedule-prompt-field", "Say what")

      assert Schedules.list({:project, project.id}) == []
    end

    test "?thread= picks that thread", %{conn: conn, project: project} do
      thread = idle_thread!(project, "Fix the pump").id

      {:ok, view, _html} = new_page(conn, "?thread=#{thread}")
      assert has_element?(view, ~s(#schedule-target option[value="#{thread}"][selected]))

      {:ok, view, _html} = new_page(conn, "?thread=th_elsewhere")
      assert has_element?(view, ~s(#schedule-target option[value="new_thread"][selected]))
    end

    test "a one-off saved for the current minute fires at once", %{conn: conn, project: project} do
      :ok = Schedules.subscribe()
      {:ok, view, _html} = new_page(conn)

      # The browser's input goes down to the minute, so this is up to 59 seconds ago.
      minute = %{DateTime.utc_now() | second: 0, microsecond: {0, 0}}

      {:ok, _page, _html} =
        view
        |> submit(%{prompt: "Check the backups", repeat: "once"}, DateTime.to_iso8601(minute))
        |> follow_redirect(conn, ~p"/projects/garden")

      project_id = project.id
      assert_receive {:schedules_changed, ^project_id}
      assert_receive {:schedules_changed, ^project_id}, 5_000

      assert [%{schedule: %Schedule{last_outcome: "started", last_thread_id: thread_id}}] =
               Schedules.list({:project, project.id})

      assert [%{id: ^thread_id}] = Threads.list(project.id)
      idle!(thread_id)
    end

    test "typing marks the form unsaved", %{conn: conn} do
      {:ok, view, _html} = new_page(conn)

      view |> form("#schedule-form", schedule: %{prompt: "Check"}) |> render_change()

      assert has_element?(view, ~s(#schedule-form[data-dirty="true"]))
      assert has_element?(view, "#schedule-dirty")
    end
  end

  describe "editing a schedule" do
    test "shows the saved values, when it runs next, and that it hasn't run", %{
      conn: conn,
      project: project
    } do
      thread = idle_thread!(project, "Fix the pump").id

      schedule =
        schedule!(project, %{
          "prompt" => "Water the beds",
          "repeat" => "every",
          "every" => "36",
          "unit" => "hours",
          "target" => thread
        })

      {:ok, view, _html} = edit_page(conn, schedule)

      assert field(view, "#schedule-heading") =~ "Schedule"
      assert field(view, "#schedule-prompt") =~ "Water the beds"
      assert has_element?(view, "#schedule-repeat-every[checked]")
      assert has_element?(view, ~s(#schedule-every[value="36"]))
      assert has_element?(view, ~s(#schedule-unit option[value="hours"][selected]))
      assert has_element?(view, ~s(#schedule-target option[value="#{thread}"][selected]))
      assert has_element?(view, ~s(#schedule-version[value="1"]))
      assert has_element?(view, ~s(#schedule-form[data-dirty="false"]))

      assert text(view, "#schedule-next") =~ ~r/^Every 36 hours · next \w{3} \d+, \d\d:\d\d UTC$/
      assert text(view, "#schedule-last") == "Hasn't run yet."
      assert has_element?(view, "#schedule-restart-note", "Saving starts the schedule over")
    end

    test "saving replaces the task and returns to the project", %{conn: conn, project: project} do
      schedule = schedule!(project)
      {:ok, view, _html} = edit_page(conn, schedule)

      {:ok, _page, html} =
        view
        |> submit(%{prompt: "Check the pumps"}, at(:timer.hours(3)))
        |> follow_redirect(conn, ~p"/projects/garden")

      assert html =~ "Schedule saved."

      assert %{schedule: %Schedule{version: 2, prompt: "Check the pumps", task_id: task_id}} =
               Schedules.get(schedule.id)

      refute task_id == schedule.task_id
      :ok = Scheduler.sync()
      assert [%TaskRecord{id: ^task_id}] = Durable.live_tasks("routine")
    end

    test "Run now flashes what it did and shows the last run", %{conn: conn, project: project} do
      schedule = schedule!(project)
      {:ok, view, _html} = edit_page(conn, schedule)

      view |> element("#schedule-run") |> render_click()

      assert has_element?(view, "#flash-info", "Started a thread.")
      %Schedule{last_thread_id: thread_id} = Photon.Repo.get!(Schedule, schedule.id)
      idle!(thread_id)
      _ = render(view)

      assert text(view, "#schedule-last") =~ ~r/^Last ran \w{3} \d+, \d\d:\d\d UTC: started "/
      path = "/projects/garden/threads/#{thread_id}"
      assert has_element?(view, ~s(#schedule-status-last-thread[href="#{path}"]))
    end

    test "Delete removes it and returns to the project", %{conn: conn, project: project} do
      schedule = schedule!(project)
      {:ok, view, _html} = edit_page(conn, schedule)

      assert has_element?(
               view,
               ~s(#schedule-delete[data-confirm="Delete this schedule? Threads it started stay."])
             )

      {:ok, page, html} =
        view
        |> element("#schedule-delete")
        |> render_click()
        |> follow_redirect(conn, ~p"/projects/garden")

      assert html =~ "Schedule deleted."
      assert Schedules.get(schedule.id) == nil
      assert has_element?(page, "#no-schedules")
      assert Schedules.list({:project, project.id}) == []
    end
  end

  describe "changes made elsewhere" do
    test "a firing updates the last run and leaves the typed prompt", %{
      conn: conn,
      project: project
    } do
      schedule = schedule!(project)
      {:ok, view, _html} = edit_page(conn, schedule)

      view
      |> form("#schedule-form", schedule: %{prompt: "Check the backups and the pumps"})
      |> render_change()

      # From another process, as the routine's firing does it.
      assert Schedules.run_now(schedule.id) == {:ok, "started"}
      %Schedule{last_thread_id: thread_id} = Photon.Repo.get!(Schedule, schedule.id)
      idle!(thread_id)
      _ = :sys.get_state(Durable.Store)

      assert text(view, "#schedule-last") =~ ~r/: started "/
      assert field(view, "#schedule-prompt") =~ "Check the backups and the pumps"
      assert has_element?(view, ~s(#schedule-form[data-dirty="true"]))
      refute has_element?(view, "#schedule-stale")
    end

    test "an edit elsewhere shows the banner; a save over it is refused and keeps the text", %{
      conn: conn,
      project: project
    } do
      schedule = schedule!(project)
      {:ok, view, _html} = edit_page(conn, schedule)

      view
      |> form("#schedule-form", schedule: %{prompt: "Mine"})
      |> render_change()

      params = Schedules.edit_params(schedule)
      {:ok, _saved} = Schedules.update(schedule.id, %{params | "prompt" => "Theirs"}, 1)

      assert has_element?(view, "#schedule-stale", "This schedule changed since you opened it.")
      assert field(view, "#schedule-prompt") =~ "Mine"

      submit(view, %{prompt: "Mine"}, params["at"])

      assert has_element?(view, "#schedule-stale")
      assert field(view, "#schedule-prompt") =~ "Mine"
      assert %{schedule: %Schedule{prompt: "Theirs", version: 2}} = Schedules.get(schedule.id)

      view |> element("#schedule-reload") |> render_click()

      refute has_element?(view, "#schedule-stale")
      assert field(view, "#schedule-prompt") =~ "Theirs"
      assert has_element?(view, ~s(#schedule-version[value="2"]))
    end

    test "Keep my text saves over the other edit", %{conn: conn, project: project} do
      schedule = schedule!(project)
      {:ok, view, _html} = edit_page(conn, schedule)
      params = Schedules.edit_params(schedule)

      {:ok, _saved} = Schedules.update(schedule.id, %{params | "prompt" => "Theirs"}, 1)
      submit(view, %{prompt: "Mine"}, params["at"])
      assert has_element?(view, "#schedule-stale")

      view |> element("#schedule-keep") |> render_click()
      refute has_element?(view, "#schedule-stale")
      assert has_element?(view, ~s(#schedule-version[value="2"]))

      {:ok, _page, _html} =
        view
        |> submit(%{prompt: "Mine"}, params["at"])
        |> follow_redirect(conn, ~p"/projects/garden")

      assert %{schedule: %Schedule{prompt: "Mine", version: 3}} = Schedules.get(schedule.id)
    end

    test "a delete elsewhere returns to the project page", %{conn: conn, project: project} do
      schedule = schedule!(project)
      {:ok, view, _html} = edit_page(conn, schedule)

      :ok = Schedules.delete(schedule.id)

      flash = assert_redirect(view, ~p"/projects/garden")
      assert flash["error"] == "That schedule was deleted."
    end
  end

  defp iso_seconds(iso) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(iso)
    DateTime.to_unix(datetime)
  end
end
