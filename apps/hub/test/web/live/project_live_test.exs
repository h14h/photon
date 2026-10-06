defmodule PhotonWeb.ProjectLiveTest do
  @moduledoc """
  A project's page, at `/projects/:slug`: its name, folder and purpose, and
  its threads, context files, skills and schedules as streams kept current.

  Threads run on the scripted model (`Photon.Threads.MockScript`). A thread
  that stays running makes a `shell` call on a stand-in machine: the test
  process registers as `box` and never answers, so the call waits until the
  test stops it. Every test leaves its threads idle, so no run outlives it.
  """

  use PhotonWeb.ConnCase, async: false

  import Ecto.Query, only: [where: 2]
  import Phoenix.LiveViewTest

  alias Photon.{Durable, Machines, Projects, Schedules, Settings, Skills, Threads}
  alias Photon.Durable.Tx
  alias Photon.Schedules.{Routine, Schedule}

  @moduletag :durable

  setup do
    {:ok, project} =
      Projects.create(%{
        "purpose" => "Keep the garden **watered** through winter.",
        "name" => "Garden"
      })

    %{project: project}
  end

  # Stands in for a connected machine that takes commands and never answers.
  defp fake_machine(name) do
    :ok =
      Machines.register(name, %{
        "platform" => "test",
        "workspace" => "/w",
        "version" => "0",
        "capabilities" => ["ops:2"]
      })
  end

  # Starts a thread and waits until it has answered; returns its ID.
  defp idle_thread!(project, text) do
    {:ok, thread} = Threads.start(project.id, text)
    idle!(thread.id)
  end

  defp idle!(thread_id) do
    until(thread_id, fn -> not Threads.busy?(thread_id) end)
    thread_id
  end

  # Waits until `fun` holds after one of the thread's commits.
  defp until(thread_id, fun) do
    :ok = Threads.subscribe(thread_id)
    if not fun.(), do: await_change(thread_id, fn _changes -> fun.() end)
    :ok
  end

  # The commit that made the state the test waited for has broadcast once
  # the store has handled it; then the page has its messages queued before
  # this render.
  defp settled(view) do
    _ = :sys.get_state(Photon.Durable.Store)
    render(view)
  end

  # The DOM IDs of the rows in a stream container, in page order.
  defp row_ids(view, container, prefix) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{container} > [id^=#{prefix}]")
    |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))
  end

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

  test "shows the name, the folder and the purpose", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")

    assert view |> element("#project-name") |> render() =~ "Garden"
    assert view |> element("#project-folder") |> render() =~ "garden"
    assert has_element?(view, "#project-purpose strong", "watered")
  end

  test "links to a new thread and a new file", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")

    assert has_element?(view, ~s(#project-new-thread[href="/projects/garden/threads/new"]))
    assert has_element?(view, ~s(#new-file[href="/projects/garden/files/new"]))
  end

  test "edits the name and purpose; the slug stays", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")
    refute has_element?(view, "#project-edit-form")

    view |> element("#edit-project") |> render_click()
    assert has_element?(view, "#project-edit-form")
    refute has_element?(view, "#project-purpose")

    html =
      view
      |> form("#project-edit-form", project: %{name: "Garden", purpose: ""})
      |> render_submit()

    assert html =~ "Say what the project is for."
    assert has_element?(view, "#project-edit-form")

    view
    |> form("#project-edit-form", project: %{name: "Back garden", purpose: "Grow tomatoes."})
    |> render_submit()

    refute has_element?(view, "#project-edit-form")
    assert view |> element("#project-name") |> render() =~ "Back garden"
    assert view |> element("#project-purpose") |> render() =~ "Grow tomatoes."
    assert view |> element("#project-folder") |> render() =~ "garden"
    assert %{name: "Back garden", slug: "garden"} = Projects.get(project.id)
  end

  test "cancel leaves the project as it was", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")

    view |> element("#edit-project") |> render_click()
    view |> element("#project-cancel") |> render_click()

    refute has_element?(view, "#project-edit-form")
    assert has_element?(view, "#project-purpose", "watered")
  end

  test "an empty project says so in both lists", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")

    assert has_element?(
             view,
             "#project-threads[phx-update=stream] #no-threads",
             "No threads yet."
           )

    assert has_element?(view, "#context-files[phx-update=stream] #no-files", "No context files")
  end

  test "lists threads newest first, marks a running one, and a message moves an old one up",
       %{conn: conn, project: project} do
    fake_machine("box")
    older = idle_thread!(project, "Fix the pump")
    newer = idle_thread!(project, "Plant the beds")

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")

    assert row_ids(view, "#project-threads", "project-thread-") == [
             "project-thread-#{newer}",
             "project-thread-#{older}"
           ]

    path = "/projects/garden/threads/#{older}"
    assert has_element?(view, ~s(#project-thread-#{older}[href="#{path}"]), "Fix the pump")
    refute has_element?(view, "#project-thread-#{older}[data-running]")

    {:ok, _submission} = Threads.send(older, "on box: $ sleep 1000")
    until(older, fn -> Threads.busy?(older) end)
    _ = settled(view)

    assert row_ids(view, "#project-threads", "project-thread-") == [
             "project-thread-#{older}",
             "project-thread-#{newer}"
           ]

    assert has_element?(view, "#project-thread-#{older}[data-running=true]", "running")
    refute has_element?(view, "#project-thread-#{newer}[data-running]")

    Threads.stop(older)
    idle!(older)
    _ = settled(view)

    refute has_element?(view, "#project-thread-#{older}[data-running]")
  end

  test "a thread started elsewhere appears", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")

    thread = idle_thread!(project, "Fix the pump")
    _ = settled(view)

    assert has_element?(view, "#project-thread-#{thread}", "Fix the pump")
  end

  test "lists context files, and one a thread writes appears", %{conn: conn, project: project} do
    thread = idle_thread!(project, "Fix the pump")
    {:ok, plan} = Projects.create_file(project.id, %{name: "plan.md", content: "Water daily."})

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")

    assert has_element?(
             view,
             ~s(#context-file-#{plan.id}[href="/projects/garden/files/plan.md"]),
             "plan.md"
           )

    assert has_element?(view, "#context-file-#{plan.id}", "by you")

    {:ok, %{file: notes}} =
      Durable.commit(&Projects.write_file_tx(&1, project.id, "notes.md", "# Pump\n", thread))

    _ = render(view)

    assert has_element?(view, "#context-file-#{notes.id}", "notes.md")
    assert has_element?(view, "#context-file-#{notes.id}", ~s(by "Fix the pump"))

    assert row_ids(view, "#context-files", "context-file-") == [
             "context-file-#{notes.id}",
             "context-file-#{plan.id}"
           ]
  end

  test "redraws how long ago things happened once a minute", %{conn: conn, project: project} do
    thread = idle_thread!(project, "Fix the pump")
    {:ok, plan} = Projects.create_file(project.id, %{name: "plan.md", content: "Water daily."})
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")

    assert has_element?(view, "#project-thread-#{thread}", "just now")
    assert has_element?(view, "#context-file-#{plan.id}", "changed just now by you")

    # Time passes without anything announcing it.
    {1, _} =
      Photon.Repo.update_all(where(Photon.Threads.Thread, id: ^thread),
        set: [active_at: DateTime.add(DateTime.utc_now(), -2, :hour)]
      )

    {1, _} =
      Photon.Repo.update_all(where(Photon.Projects.ContextFile, id: ^plan.id),
        set: [updated_at: DateTime.add(DateTime.utc_now(), -3, :hour)]
      )

    send(view.pid, :tick)

    assert has_element?(view, "#project-thread-#{thread}", "2 hours ago")
    assert has_element?(view, "#context-file-#{plan.id}", "changed 3 hours ago by you")
  end

  test "an unknown slug goes home with a flash", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/", flash: flash}}} =
             live(conn, ~p"/projects/orchard")

    assert flash["error"] == "There's no project called orchard."
  end

  describe "skills" do
    defp skill!(name, description \\ "Use it when the task calls for it.") do
      {:ok, skill} =
        Skills.create(%{"name" => name, "description" => description, "instructions" => "Do it."})

      skill
    end

    test "with no skills at all, the picker points to the Skills page", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")

      assert has_element?(view, "#project-skills[phx-update=stream] #no-project-skills")
      refute has_element?(view, "#project-skill-picker")

      view |> element("#project-add-skill") |> render_click()

      assert has_element?(view, "#project-skill-picker", "No skills yet.")
      assert has_element?(view, ~s(#project-skills-page[href="/skills"]))

      view |> element("#project-add-skill") |> render_click()
      refute has_element?(view, "#project-skill-picker")
    end

    test "the picker turns a skill on, and Turn off turns it off", %{conn: conn, project: project} do
      pdf = skill!("pdf-forms", "Fill in PDF forms.")
      notes = skill!("release-notes")
      :ok = Skills.enable(notes.id, :blip)

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")
      view |> element("#project-add-skill") |> render_click()

      assert has_element?(view, "#project-skill-option-#{pdf.id}", "Fill in PDF forms.")
      assert has_element?(view, "#project-skill-option-#{notes.id}", "release-notes")

      view |> element("#project-skill-option-#{pdf.id}") |> render_click()

      assert has_element?(view, ~s(#project-skill-#{pdf.id}-link[href="/skills/pdf-forms"]))
      assert has_element?(view, "#project-skill-#{pdf.id}", "Fill in PDF forms.")
      refute has_element?(view, "#project-skill-option-#{pdf.id}")
      assert row_ids(view, "#project-skills", "project-skill-") == ["project-skill-#{pdf.id}"]
      assert Skills.scopes(pdf.id) == [{:project, project.id}]

      view |> element("#project-skill-#{pdf.id}-off") |> render_click()

      refute has_element?(view, "#project-skill-#{pdf.id}")
      assert has_element?(view, "#project-skill-option-#{pdf.id}")
      assert Skills.scopes(pdf.id) == []
      assert Skills.scopes(notes.id) == [:blip]
    end

    test "a refused enable says why in the picker", %{conn: conn, project: project} do
      _pdf = skill!("pdf-forms")
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")
      view |> element("#project-add-skill") |> render_click()

      render_click(view, "enable_skill", %{"id" => "sk_missing"})

      assert has_element?(view, "#project-skill-picker #project-skill-error", "deleted")
    end

    test "a toggle made elsewhere, or a new skill, shows on the open page", %{
      conn: conn,
      project: project
    } do
      pdf = skill!("pdf-forms")
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")
      view |> element("#project-add-skill") |> render_click()

      # As the Skills page or a skill's page would.
      :ok = Skills.enable(pdf.id, {:project, project.id})
      assert has_element?(view, "#project-skill-#{pdf.id}")
      refute has_element?(view, "#project-skill-option-#{pdf.id}")

      notes = skill!("release-notes")
      assert has_element?(view, "#project-skill-option-#{notes.id}")

      :ok = Skills.disable(pdf.id, {:project, project.id})
      refute has_element?(view, "#project-skill-#{pdf.id}")
      assert row_ids(view, "#project-skills", "project-skill-") == []
    end
  end

  describe "schedules" do
    # An ISO 8601 time `ms` from now, as the form's hook sends it.
    defp at(ms), do: DateTime.utc_now() |> DateTime.add(ms, :millisecond) |> DateTime.to_iso8601()

    defp schedule!(project, overrides \\ %{}) do
      params =
        Map.merge(
          %{
            "prompt" => "Check the backups",
            "at" => at(:timer.hours(1)),
            "repeat" => "once",
            "target" => "new_thread"
          },
          overrides
        )

      {:ok, %Schedule{} = schedule} = Schedules.create({:project, project.id}, params)
      schedule
    end

    test "an empty project says so, and links to a new schedule", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")

      assert has_element?(view, "#project-schedules[phx-update=stream] #no-schedules")
      assert has_element?(view, ~s(#new-schedule[href="/projects/garden/schedules/new"]))
      refute has_element?(view, "#schedules-consent")
    end

    test "each row says when it runs and where it goes", %{conn: conn, project: project} do
      thread = idle_thread!(project, "Fix the pump")
      once = schedule!(project)

      daily =
        schedule!(project, %{
          "prompt" => "Water the beds",
          "repeat" => "every",
          "every" => "1",
          "unit" => "days",
          "target" => thread
        })

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")
      ids = row_ids(view, "#project-schedules", "schedule-")
      assert ids == ["schedule-#{once.id}", "schedule-#{daily.id}"]

      assert has_element?(view, "#schedule-#{once.id}-prompt", "Check the backups")
      assert text(view, "#schedule-#{once.id}-when") =~ ~r/^Once · \w{3} \d+, \d\d:\d\d UTC$/
      assert has_element?(view, "#schedule-#{once.id}-when time[datetime]")
      assert has_element?(view, "#schedule-#{once.id}-target", "Starts a new thread each time")
      refute has_element?(view, "#schedule-#{once.id}-last")

      assert text(view, "#schedule-#{daily.id}-when") =~ "Every day · next"
      assert text(view, "#schedule-#{daily.id}-target") == ~s(Wakes "Fix the pump")

      assert has_element?(
               view,
               ~s(#schedule-#{daily.id}-thread[href="/projects/garden/threads/#{thread}"])
             )

      assert has_element?(
               view,
               ~s(#schedule-#{daily.id}-edit[href="/projects/garden/schedules/#{daily.id}"])
             )

      assert has_element?(
               view,
               ~s(#schedule-#{daily.id}-delete[data-confirm="Delete this schedule? Threads it started stay."])
             )
    end

    test "a prompt shows its own line breaks and nothing before them", %{
      conn: conn,
      project: project
    } do
      schedule = schedule!(project, %{"prompt" => "Check the backups\nThen the logs"})
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")

      prompt =
        view
        |> element("#schedule-#{schedule.id}-prompt")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()

      assert prompt == "Check the backups\nThen the logs"
    end

    test "a firing elsewhere updates the row, and a rename of its thread follows", %{
      conn: conn,
      project: project
    } do
      schedule = schedule!(project)
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")

      # From another process, as the routine's firing does it.
      assert Schedules.run_now(schedule.id) == {:ok, "started"}
      %Schedule{last_thread_id: thread_id} = Photon.Repo.get!(Schedule, schedule.id)
      idle!(thread_id)
      _ = settled(view)

      last = "#schedule-#{schedule.id}-last"
      title = Threads.get(thread_id).title
      assert text(view, last) =~ ~r/^Last ran \w{3} \d+, \d\d:\d\d UTC: started "#{title}"$/
      assert has_element?(view, "#{last}-at[datetime]")
      path = "/projects/garden/threads/#{thread_id}"
      assert has_element?(view, ~s(#{last}-thread[href="#{path}"]), title)
      assert has_element?(view, "#project-thread-#{thread_id}")

      {:ok, _thread} = Threads.rename(thread_id, "Backup check")
      _ = settled(view)

      assert has_element?(view, "#{last}-thread", ~s("Backup check"))
    end

    test "Run now flashes what it did and starts a thread", %{conn: conn, project: project} do
      schedule = schedule!(project)
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")

      view |> element("#schedule-#{schedule.id}-run") |> render_click()

      assert has_element?(view, "#flash-info", "Started a thread.")

      %Schedule{last_thread_id: thread_id, last_outcome: "started"} =
        Photon.Repo.get!(Schedule, schedule.id)

      assert [%{id: ^thread_id}] = Threads.list(project.id)
      idle!(thread_id)
      _ = settled(view)

      assert has_element?(view, "#project-thread-#{thread_id}")
      assert has_element?(view, "#schedule-#{schedule.id}-last-thread")
    end

    test "Run now into a thread names it", %{conn: conn, project: project} do
      thread = idle_thread!(project, "Fix the pump")
      schedule = schedule!(project, %{"target" => thread})
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")

      view |> element("#schedule-#{schedule.id}-run") |> render_click()
      idle!(thread)

      assert has_element?(view, "#flash-info", ~s(Sent to "Fix the pump".))
      assert text(view, "#schedule-#{schedule.id}-last") =~ ~r/: sent$/
    end

    test "Delete removes the schedule", %{conn: conn, project: project} do
      schedule = schedule!(project)
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")

      view |> element("#schedule-#{schedule.id}-delete") |> render_click()

      refute has_element?(view, "#schedule-#{schedule.id}")
      assert row_ids(view, "#project-schedules", "schedule-") == []
      assert has_element?(view, "#flash-info", "Schedule deleted.")
      assert Schedules.get(schedule.id) == nil
    end

    test "Run now and Delete ignore a schedule that isn't this project's", %{
      conn: conn,
      project: project
    } do
      {:ok, house} = Projects.create(%{"name" => "House", "purpose" => "Fix the roof."})
      other = schedule!(house)
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")

      render_click(view, "delete_schedule", %{"id" => other.id})
      render_click(view, "run_schedule", %{"id" => other.id})

      assert %{schedule: %Schedule{last_run_at: nil}} = Schedules.get(other.id)
    end

    test "a schedule whose task failed says it stopped, and how to start it again", %{
      conn: conn,
      project: project
    } do
      schedule = schedule!(project, %{"repeat" => "every", "every" => "1", "unit" => "days"})
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")

      task = Durable.task(schedule.task_id)

      :ok =
        Durable.commit(fn tx ->
          _failed = Tx.finish(tx, task, "failed", %{"status" => "failed", "reason" => "boom"})
          Routine.on_fail(task, "boom", tx)
        end)

      _ = settled(view)

      assert has_element?(view, "#schedule-#{schedule.id}-when[data-state=stopped]")

      assert text(view, "#schedule-#{schedule.id}-when") ==
               "Stopped after an error: boom. Save it to start it again."

      refute has_element?(view, "#schedule-#{schedule.id}-last")
    end
  end

  describe "schedules while scheduled work is off" do
    setup do
      # Off the scripted model, consent is the setting, which starts off.
      Application.put_env(:photon, :mock_model, false)
      on_exit(fn -> Application.put_env(:photon, :mock_model, true) end)
      refute Schedules.consent?()
      :ok
    end

    test "a banner says they skip, until it is turned on", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")
      refute has_element?(view, "#schedules-consent")

      _schedule = schedule!(project)
      _ = settled(view)

      assert has_element?(view, "#schedules-consent", "Scheduled work is off")
      assert has_element?(view, ~s(#schedules-consent-settings[href="/settings"]))

      _settings = Settings.save(%{"scheduled_work" => "true"})
      _ = render(view)

      refute has_element?(view, "#schedules-consent")
    end

    test "a skipped run links to Settings", %{conn: conn, project: project} do
      :ok = Schedules.subscribe()
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")

      schedule = schedule!(project, %{"at" => at(0)})
      project_id = project.id
      assert_receive {:schedules_changed, ^project_id}
      # Its time has come, so the routine fires it at once, and skips.
      assert_receive {:schedules_changed, ^project_id}, 5_000
      _ = settled(view)

      last = "#schedule-#{schedule.id}-last"
      assert text(view, last) =~ ~r/: skipped: scheduled work is off$/
      assert has_element?(view, ~s(#{last}-settings[href="/settings"]))
      assert has_element?(view, "#schedules-consent")
      assert Threads.list(project.id) == []
    end
  end
end
