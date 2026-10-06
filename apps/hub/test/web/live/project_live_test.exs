defmodule PhotonWeb.ProjectLiveTest do
  @moduledoc """
  A project's page, at `/projects/:slug`: its name, folder and purpose, and
  its threads and context files as streams kept current.

  Threads run on the scripted model (`Photon.Threads.MockScript`). A thread
  that stays running makes a `shell` call on a stand-in machine: the test
  process registers as `box` and never answers, so the call waits until the
  test stops it. Every test leaves its threads idle, so no run outlives it.
  """

  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Photon.{Durable, Machines, Projects, Threads}

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

  test "an unknown slug goes home with a flash", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/", flash: flash}}} =
             live(conn, ~p"/projects/orchard")

    assert flash["error"] == "There's no project called orchard."
  end
end
