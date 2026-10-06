defmodule PhotonWeb.SidebarTest do
  @moduledoc """
  The sidebar on every page (`PhotonWeb.Layouts`, fed by `PhotonWeb.Shell`):
  Home, the projects with their threads, Machines and Settings, kept current
  as projects and threads change.

  Threads run on the scripted model (`Photon.Threads.MockScript`). A thread
  that stays running makes a `shell` call on a stand-in machine: the test
  process registers as `box` and never answers, so the call waits until the
  test stops it. Every test leaves its threads idle, so no run outlives it.
  """

  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Photon.{Machines, Projects, Threads}

  @moduletag :durable

  setup %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    %{view: view}
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

  defp project!(name) do
    {:ok, project} = Projects.create(%{"purpose" => "Keep the #{name} going.", "name" => name})
    project
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

  defp count(view, selector) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()
  end

  test "has Home, Projects, Machines with the online count, and Settings", %{view: view} do
    assert has_element?(view, "#nav-home[href='/']")
    assert has_element?(view, "#new-project[href='/projects/new']")
    assert has_element?(view, "#nav-machines[href='/nodes']", "0 online")
    assert has_element?(view, "#nav-settings")
    assert has_element?(view, "#no-projects")
    refute has_element?(view, "#nav-overview")
    refute has_element?(view, "#nav-nodes")

    {:ok, _key} = Photon.NodeKeys.issue("nas")
    fake_machine("box")
    Machines.broadcast()
    _ = render(view)

    assert has_element?(view, "#nav-machines", "1 online")
    refute has_element?(view, "[id^=side-node-]")
  end

  test "asks for a ChatGPT sign-in only while no model can answer", %{conn: conn, view: view} do
    # The scripted model answers everything, so there's nothing to sign in for.
    refute has_element?(view, "#sign-in-banner")

    Photon.ChatGPTStub.reset!()
    Application.put_env(:photon, :mock_model, false)
    on_exit(fn -> Application.put_env(:photon, :mock_model, true) end)

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#sign-in-banner[href='/settings']", "Sign in with ChatGPT")
  end

  test "a project made elsewhere appears, with a + to start a thread", %{view: view} do
    task = Task.async(fn -> project!("Garden") end)
    _project = Task.await(task)
    _ = settled(view)

    refute has_element?(view, "#no-projects")
    assert has_element?(view, "#side-project-garden[href='/projects/garden']", "Garden")
    assert has_element?(view, "#new-thread-garden[href='/projects/garden/threads/new']")
  end

  test "a started thread is listed, marked while it runs", %{view: view} do
    fake_machine("box")
    project = project!("Garden")
    {:ok, thread} = Threads.start(project.id, "on box: $ sleep 1000")
    until(thread.id, fn -> Threads.busy?(thread.id) end)
    _ = settled(view)

    path = "/projects/garden/threads/#{thread.id}"
    assert has_element?(view, "#side-thread-#{thread.id}[href='#{path}']", "on box")
    assert has_element?(view, "#side-thread-#{thread.id}[data-running=true]")

    Threads.stop(thread.id)
    idle!(thread.id)
    _ = settled(view)

    assert has_element?(view, "#side-thread-#{thread.id}")
    refute has_element?(view, "#side-thread-#{thread.id}[data-running]")
  end

  test "lists five threads and how many more; a message brings an old one back", %{view: view} do
    fake_machine("box")
    project = project!("Garden")
    [oldest | newer] = for n <- 1..6, do: idle_thread!(project, "thread #{n}")
    _ = settled(view)

    for id <- newer, do: assert(has_element?(view, "#side-thread-#{id}"))
    refute has_element?(view, "#side-thread-#{oldest}")
    assert has_element?(view, "#side-more-garden[href='/projects/garden']", "1 more")

    {:ok, _submission} = Threads.send(oldest, "on box: $ sleep 1000")
    until(oldest, fn -> Threads.busy?(oldest) end)
    _ = settled(view)

    assert has_element?(view, "#side-thread-#{oldest}[data-running=true]")
    refute has_element?(view, "#side-thread-#{hd(newer)}")
    assert has_element?(view, "#side-more-garden", "1 more")

    Threads.stop(oldest)
    idle!(oldest)
  end

  test "a running thread stays listed past the five until it stops", %{view: view} do
    fake_machine("box")
    project = project!("Garden")
    {:ok, running} = Threads.start(project.id, "on box: $ sleep 1000")
    until(running.id, fn -> Threads.busy?(running.id) end)
    for n <- 1..5, do: idle_thread!(project, "thread #{n}")
    _ = settled(view)

    assert has_element?(view, "#side-thread-#{running.id}[data-running=true]")
    refute has_element?(view, "#side-more-garden")

    Threads.stop(running.id)
    idle!(running.id)
    _ = settled(view)

    refute has_element?(view, "#side-thread-#{running.id}")
    assert has_element?(view, "#side-more-garden", "1 more")
  end

  test "a project called Garden more doesn't collide with Garden's more link", %{view: view} do
    garden = project!("Garden")
    _more = project!("Garden more")
    for n <- 1..6, do: idle_thread!(garden, "thread #{n}")
    _ = settled(view)

    assert count(view, "#side-project-garden-more") == 1
    assert count(view, "#side-more-garden") == 1
    assert count(view, "#side-project-garden") == 1
  end

  test "marks the page on screen", %{conn: conn} do
    project = project!("Garden")
    thread = idle_thread!(project, "Fix the pump")

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#nav-home[aria-current=page]")

    {:ok, view, _html} = live(conn, ~p"/projects/garden")
    assert has_element?(view, "#side-project-garden[aria-current=page]")

    {:ok, view, _html} = live(conn, ~p"/projects/garden/threads/#{thread}")
    assert has_element?(view, "#side-thread-#{thread}[aria-current=page]")
    assert has_element?(view, "#side-project-garden.font-medium")
    refute has_element?(view, "#side-project-garden[aria-current]")

    {:ok, view, _html} = live(conn, ~p"/nodes")
    assert has_element?(view, "#nav-machines[aria-current=page]")
  end
end
