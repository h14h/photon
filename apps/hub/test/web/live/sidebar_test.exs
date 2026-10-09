defmodule PhotonWeb.SidebarTest do
  @moduledoc """
  The sidebar on every page (`PhotonWeb.Layouts`, fed by `PhotonWeb.Shell`):
  Home, Activity, the projects with their threads, Machines, Skills and Settings, kept current
  as projects and threads change.

  Threads run on the scripted model (`Photon.Threads.MockScript`). A thread
  that stays running makes a `shell` call on a stand-in machine: the test
  process registers as `box` and never answers, so the call waits until the
  test stops it. Every test leaves its threads idle, so no run outlives it.
  """

  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Photon.ConversationHelpers
  import PhotonWeb.LiveHelpers
  import Photon.MachineOps, only: [fake_machine: 1]

  alias Photon.{Assistant, Machines, Projects, Questions, Threads}

  @moduletag :durable

  setup %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    %{view: view}
  end

  defp project!(name) do
    {:ok, project} = Projects.create(%{"purpose" => "Keep the #{name} going.", "name" => name})
    project
  end

  defp count(view, selector) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()
  end

  test "has Home, Activity, Projects, Machines with the online count, and Settings", %{
    view: view
  } do
    assert has_element?(view, "#nav-home[href='/']")
    assert has_element?(view, "#nav-activity[href='/activity']", "Activity")
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
    Photon.TestConfig.put_env(:photon, :mock_model, false)

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#sign-in-banner[href='/settings']", "Sign in with ChatGPT")
  end

  test "Home counts the threads that need you, and each thread is marked with its state", %{
    view: view
  } do
    refute has_element?(view, "#nav-home-count")

    # Blip waits on a command that never finishes, so a thread's question
    # stays with it and the thread stays asking.
    fake_machine("box")
    {:ok, _parked} = Assistant.send("on box: $ sleep 1000")
    project = project!("Garden")
    :ok = Questions.subscribe()

    waiting = idle_thread!(project, "ask me: which zone should I water first").id
    failed = idle_thread!(project, "fail: the pump is unplugged").id
    unread = idle_thread!(project, "files").id
    {:ok, asking} = Threads.start(project.id, "ask blip: which deploy branch?")
    asking_id = asking.id
    assert_receive {:questions_changed, ^asking_id}, 5_000
    _ = settled(view)

    # Waiting on you, failed and unread count; asking Blip doesn't.
    assert has_element?(view, "#nav-home-count", "3")
    assert has_element?(view, "#nav-home-count[title='3 things need you.']")

    for {id, state, words} <- [
          {asking.id, "asking", "Asking Blip"},
          {waiting, "waiting", "Waiting on you"},
          {failed, "failed", "Failed"},
          {unread, "unread", "Finished"}
        ] do
      assert has_element?(view, "#side-thread-#{id}[data-state=#{state}]")
      assert has_element?(view, ~s(#side-thread-#{id} [data-mark=#{state}][title="#{words}"]))
    end

    # The thread asking Blip is busy, but doesn't show the running dot.
    refute has_element?(view, "#side-thread-#{asking.id} [data-mark=running]")

    :ok = Threads.resolve(failed)
    :ok = Threads.mark_seen(unread)
    _ = settled(view)

    assert has_element?(view, "#nav-home-count", "1")
    assert has_element?(view, "#side-thread-#{failed}[data-state=idle]")
    refute has_element?(view, "#side-thread-#{failed} [data-mark]")

    :ok = Threads.resolve(waiting)
    _ = settled(view)
    refute has_element?(view, "#nav-home-count")

    # Stop the thread asking Blip, so no run outlives the test.
    Threads.stop(asking.id)
    idle!(asking.id)
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
    await_until(thread.id, fn -> Threads.busy?(thread.id) end)
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
    [oldest | newer] = for n <- 1..6, do: idle_thread!(project, "thread #{n}").id
    _ = settled(view)

    for id <- newer, do: assert(has_element?(view, "#side-thread-#{id}"))
    refute has_element?(view, "#side-thread-#{oldest}")
    assert has_element?(view, "#side-more-garden[href='/projects/garden']", "1 more")

    {:ok, _submission} = Threads.send(oldest, "on box: $ sleep 1000")
    await_until(oldest, fn -> Threads.busy?(oldest) end)
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
    await_until(running.id, fn -> Threads.busy?(running.id) end)
    for n <- 1..5, do: idle_thread!(project, "thread #{n}").id
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
    for n <- 1..6, do: idle_thread!(garden, "thread #{n}").id
    _ = settled(view)

    assert count(view, "#side-project-garden-more") == 1
    assert count(view, "#side-more-garden") == 1
    assert count(view, "#side-project-garden") == 1
  end

  test "marks the page on screen", %{conn: conn} do
    project = project!("Garden")
    thread = idle_thread!(project, "Fix the pump").id

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#nav-home[aria-current=page]")

    {:ok, view, _html} = live(conn, ~p"/projects/garden")
    assert has_element?(view, "#side-project-garden[aria-current=page]")

    {:ok, view, _html} = live(conn, ~p"/projects/garden/threads/#{thread}")
    assert has_element?(view, "#side-thread-#{thread}[aria-current=page]")
    assert has_element?(view, "#side-project-garden.font-medium")
    refute has_element?(view, "#side-project-garden[aria-current]")

    {:ok, view, _html} = live(conn, ~p"/activity")
    assert has_element?(view, "#nav-activity[aria-current=page]")
    refute has_element?(view, "#nav-home[aria-current]")

    {:ok, view, _html} = live(conn, ~p"/nodes")
    assert has_element?(view, "#nav-machines[aria-current=page]")
  end

  test "Skills links to the Skills page and is marked on the skills pages", %{
    conn: conn,
    view: view
  } do
    assert has_element?(view, "#nav-skills[href='/skills']", "Skills")
    refute has_element?(view, "#nav-skills[aria-current]")

    {:ok, _skill} =
      Photon.Skills.create(%{
        "name" => "pdf-forms",
        "description" => "Fill in PDF forms.",
        "instructions" => "Read the form first."
      })

    for path <- [~p"/skills", ~p"/skills/new", ~p"/skills/install", ~p"/skills/pdf-forms"] do
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, "#nav-skills[aria-current=page]"), "#{path} doesn't mark Skills"
      refute has_element?(view, "#nav-settings[aria-current]")
    end
  end
end
