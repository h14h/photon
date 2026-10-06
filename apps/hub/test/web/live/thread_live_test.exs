defmodule PhotonWeb.ThreadLiveTest do
  @moduledoc """
  A project's threads, driven as a user would: starting one from the
  new-thread page, and its conversation (a command on a machine with its
  output streaming in, an image, the composer while it runs, Stop), next to
  Blip's panel on the same page.

  Threads run on the scripted model (`Photon.Threads.MockScript`). The test
  process connects as the machine `box` (`Photon.MachineOps.connect/2`), so
  an op started on it arrives here as `{:push_op, id}`, and the test answers
  for the node through `Photon.Machines.output/3` and `snapshot/3`.
  """

  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Photon.Fixtures, only: [call: 3]

  alias Photon.{Durable, MachineOps, Machines, Projects, Threads}
  alias Photon.Durable.Tx
  alias PhotonCore.Message

  @moduletag :durable

  # Longer than a call's check (200 ms in tests), so its push has time to come.
  @wait 3_000

  setup do
    {:ok, project} =
      Projects.create(%{"purpose" => "Keep the garden watered.", "name" => "Garden"})

    %{project: project}
  end

  # Starts a thread and waits until it has answered, so no run outlives the test.
  defp idle_thread!(project, text) do
    {:ok, thread} = Threads.start(project.id, text)
    :ok = Threads.subscribe(thread.id)
    await_idle(thread.id)
    thread
  end

  defp await_idle(thread_id) do
    if Threads.busy?(thread_id),
      do: await_change(thread_id, fn _changes -> not Threads.busy?(thread_id) end, @wait)

    :ok
  end

  defp thread_page(conn, project, thread) do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/threads/#{thread.id}")
    view
  end

  # A run that waits for a signal that never comes, so the thread is busy.
  defp busy!(thread_id) do
    Durable.commit(
      &Tx.create_task(&1, %{
        kind: "generation",
        conversation_id: thread_id,
        phase: "after_tools",
        waiting: %{"signal" => "never"}
      })
    )
  end

  # A finished shell op on `box`, as the node reports it.
  defp completed(id, command, out) do
    MachineOps.snapshot(id, "completed", %{
      "input" => %{"command" => command, "shell" => "/bin/sh", "directory" => "garden"},
      "out_path" => "/data/ops/#{id}/out",
      "err_path" => "/data/ops/#{id}/err",
      "result" => %{"out" => out, "err" => "", "exit_code" => 0}
    })
  end

  describe "a new thread" do
    test "shows the project's purpose, and starts with the first message", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/threads/new")
      assert view |> element("#thread-new-heading") |> render() =~ "New thread in Garden"
      assert has_element?(view, "#thread-new-purpose", "Keep the garden watered.")
      # Focused on mount, which a live navigation runs too (autofocus alone doesn't).
      assert has_element?(view, "#thread-composer-input[autofocus][phx-mounted]")
      assert has_element?(view, ~s(#thread-project[href="/projects/garden"]))

      assert has_element?(
               view,
               ~s(#thread-composer-input[placeholder="What should this thread work on?"])
             )

      refute has_element?(view, "#thread-stop")

      {:ok, view, _html} =
        view
        |> form("#thread-composer", message: %{text: "files"})
        |> render_submit()
        |> follow_redirect(conn)

      assert [thread] = Threads.list(project.id)
      assert has_element?(view, "#thread-title", "files")
      :ok = Threads.subscribe(thread.id)
      await_idle(thread.id)
      assert has_element?(view, "#thread-entries", "This project has no context files yet.")
    end

    test "shows the purpose as Markdown", %{conn: conn, project: project} do
      {:ok, _project} =
        Projects.update(project.id, %{"purpose" => "## Goals\n- keep zone 2 **dry**"})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/threads/new")
      assert has_element?(view, "#thread-new-purpose h2", "Goals")
      assert has_element?(view, "#thread-new-purpose li strong", "dry")
    end

    test "a blank message starts nothing", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/threads/new")
      view |> form("#thread-composer", message: %{text: "  "}) |> render_submit()
      assert Threads.list(project.id) == []
    end

    test "asks for a ChatGPT sign-in instead of offering a composer", %{
      conn: conn,
      project: project
    } do
      Photon.ChatGPTStub.reset!()
      Application.put_env(:photon, :mock_model, false)
      on_exit(fn -> Application.put_env(:photon, :mock_model, true) end)

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/threads/new")
      assert has_element?(view, "#thread-sign-in-to-talk", "A thread needs a ChatGPT sign-in")
      refute has_element?(view, "#thread-composer")
    end
  end

  describe "a command on a machine" do
    setup do
      :ok = MachineOps.connect("box")
      :ok
    end

    test "names the machine, streams its output under it, and shows the result", %{
      conn: conn,
      project: project
    } do
      {:ok, thread} = Threads.start(project.id, "on box: $ ls")
      :ok = Threads.subscribe(thread.id)
      view = thread_page(conn, project, thread)

      assert_receive {:push_op, op_id}, @wait

      [%{"id" => call_id}] =
        Message.tool_calls(await_entry(thread.id, &tool_calls?/1).data["message"])

      action = "#thread-action-#{call_id}"

      assert has_element?(view, "#{action}[data-status=pending] summary", "Running ls on box")
      assert has_element?(view, "#thread-status[data-state=running]")

      Machines.output("box", %{"id" => op_id, "stream" => "out", "text" => "notes.txt\n"}, %{})
      assert has_element?(view, "#{action}-tail pre", "notes.txt")

      {_pushes, _routes} = Machines.snapshot("box", completed(op_id, "ls", "notes.txt\n"), %{})
      await_entry(thread.id, &(&1.kind == "tool_result"), @wait)
      await_idle(thread.id)

      refute has_element?(view, "#{action}-tail")
      assert has_element?(view, "#{action}[data-status=done] summary", "Ran ls on box")
      assert has_element?(view, "#{action} details pre", "notes.txt")
      assert has_element?(view, "#thread-status[data-state=idle]")
    end

    test "Stop mid-command says the call was stopped and keeps what it printed", %{
      conn: conn,
      project: project
    } do
      {:ok, thread} = Threads.start(project.id, "on box: $ for i in 1 2 3; do echo tick; done")
      :ok = Threads.subscribe(thread.id)
      view = thread_page(conn, project, thread)

      assert_receive {:push_op, op_id}, @wait

      [%{"id" => call_id}] =
        Message.tool_calls(await_entry(thread.id, &tool_calls?/1).data["message"])

      action = "#thread-action-#{call_id}"
      Machines.output("box", %{"id" => op_id, "stream" => "out", "text" => "tick 1\n"}, %{})
      assert has_element?(view, "#{action}-tail pre", "tick 1")

      view |> element("#thread-stop") |> render_click()
      await_entry(thread.id, &(&1.kind == "tool_result"), @wait)
      await_idle(thread.id)

      assert has_element?(view, "#{action}[data-status=stopped] summary", "Stopped")
      assert has_element?(view, "#{action} summary [data-machine=box]")
      assert has_element?(view, "#{action}-tail pre", "tick 1")
    end

    test "an image loads from the thread's own route", %{conn: conn, project: project} do
      thread = idle_thread!(project, "Look at the garden")
      view = thread_page(conn, project, thread)

      call = call("view_image", %{"machine" => "box", "path" => "shot.png"}, "c2")

      Durable.commit(
        &Tx.append(&1, thread.id, "assistant", %{"message" => Message.assistant("", [call])})
      )

      result =
        Durable.commit(
          &Tx.append(&1, thread.id, "tool_result", %{
            "message" =>
              Message.tool_result("c2", [
                Message.image("image/png", "iVBORw0KGgo="),
                Message.text("1x1 image/png on box")
              ]),
            "name" => "view_image",
            "status" => "ok",
            "details" => %{"machine" => "box", "kind" => "view_image", "path" => "shot.png"}
          })
        )

      src = "/threads/#{thread.id}/images/#{result.id}/0"
      assert has_element?(view, "#thread-action-c2 summary", "Looked at shot.png on box")
      assert has_element?(view, ~s(#thread-action-c2 img#thread-action-c2-image-0[src="#{src}"]))
      assert response(get(build_conn(), src), 200) == Base.decode64!("iVBORw0KGgo=")
    end
  end

  describe "while the thread runs" do
    setup %{conn: conn, project: project} do
      thread = idle_thread!(project, "Fix the pump")
      view = thread_page(conn, project, thread)
      assert has_element?(view, "#thread-status[data-state=idle]")
      refute has_element?(view, "#thread-stop")
      refute has_element?(view, "#thread-composer-input[phx-mounted]")
      _run = busy!(thread.id)
      %{thread: thread, view: view}
    end

    test "a message waits, and can be withdrawn", %{thread: thread, view: view} do
      assert has_element?(view, "#thread-status[data-state=running]")
      assert has_element?(view, "#thread-mode-toggle", "Send after this answer")
      view |> element("#thread-mode-toggle") |> render_click()
      assert has_element?(view, "#thread-mode-toggle", "Steer current work")
      view |> element("#thread-mode-toggle") |> render_click()

      view |> form("#thread-composer", message: %{text: "and then this"}) |> render_submit()
      _ = render(view)
      assert [queued] = Threads.queued(thread.id)
      assert has_element?(view, "#thread-queued-#{queued.id}", "and then this")

      view |> element("#thread-queued-#{queued.id} button") |> render_click()
      refute has_element?(view, "#thread-queued-#{queued.id}")
      assert Threads.queued(thread.id) == []
    end

    test "Stop ends the run", %{thread: thread, view: view} do
      view |> element("#thread-stop") |> render_click()
      await_change(thread.id, &Enum.any?(&1.tasks, fn t -> t.status == "aborted" end))
      _ = render(view)

      refute has_element?(view, "#thread-stop")
      refute has_element?(view, "#thread-live-output")
      assert has_element?(view, "#thread-status[data-state=idle]")
    end

    test "withdrawing a message that isn't this thread's does nothing", %{
      project: project,
      view: view
    } do
      other = idle_thread!(project, "Plan the beds")
      _run = busy!(other.id)
      {:ok, submission} = Threads.send(other.id, "and then this")

      render_click(view, "withdraw", %{"id" => submission.id})
      assert [%{id: id}] = Threads.queued(other.id)
      assert id == submission.id
      :ok = Threads.stop(other.id)
    end
  end

  test "without a model, Stop moves to the header and the sign-in keeps clear of Blip", %{
    conn: conn,
    project: project
  } do
    thread = idle_thread!(project, "Fix the pump")
    Photon.ChatGPTStub.reset!()
    Application.put_env(:photon, :mock_model, false)
    on_exit(fn -> Application.put_env(:photon, :mock_model, true) end)

    view = thread_page(conn, project, thread)
    assert has_element?(view, ".blip-clear-x > #thread-sign-in-to-talk")
    refute has_element?(view, "#thread-composer")
    refute has_element?(view, "#thread-stop")

    _run = busy!(thread.id)
    _ = render(view)
    assert has_element?(view, "header #thread-stop")

    view |> element("#thread-stop") |> render_click()
    await_change(thread.id, &Enum.any?(&1.tasks, fn t -> t.status == "aborted" end))
    _ = render(view)
    refute has_element?(view, "#thread-stop")
    assert has_element?(view, "#thread-status[data-state=idle]")
  end

  test "Blip's panel and the thread share the page without sharing an ID", %{
    conn: conn,
    project: project
  } do
    thread = idle_thread!(project, "Fix the pump")
    view = thread_page(conn, project, thread)

    ids =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[id]")
      |> LazyHTML.attribute("id")

    assert Enum.count(ids, &(&1 == "composer")) == 1
    assert Enum.count(ids, &(&1 == "thread-composer")) == 1
    assert ids -- Enum.uniq(ids) == []
  end

  test "the page keeps clear of Blip's floating panel", %{conn: conn, project: project} do
    thread = idle_thread!(project, "Fix the pump")
    assert has_element?(thread_page(conn, project, thread), "#thread-page[data-blip-room]")
  end

  test "the header follows the project's name", %{conn: conn, project: project} do
    thread = idle_thread!(project, "Fix the pump")
    view = thread_page(conn, project, thread)
    {:ok, _project} = Projects.update(project.id, %{"name" => "Orchard"})
    _ = :sys.get_state(Photon.Durable.Store)
    assert has_element?(view, "#thread-project", "Orchard")
  end

  test "an unknown project or thread, or a thread under another project, goes home",
       %{conn: conn, project: project} do
    {:ok, other} = Projects.create(%{"purpose" => "Plan the trip.", "name" => "Trip"})
    thread = idle_thread!(project, "Fix the pump")

    for {path, message} <- [
          {~p"/projects/orchard/threads/new", "There's no project called orchard."},
          {~p"/projects/orchard/threads/#{thread.id}", "There's no project called orchard."},
          {~p"/projects/#{project.slug}/threads/c_none", "There's no such thread in Garden."},
          {~p"/projects/#{other.slug}/threads/#{thread.id}", "There's no such thread in Trip."}
        ] do
      assert {:error, {:live_redirect, %{to: "/", flash: flash}}} = live(conn, path)
      assert flash["error"] == message
    end
  end

  defp tool_calls?(%{kind: "assistant", data: %{"message" => message}}),
    do: Message.tool_calls(message) != []

  defp tool_calls?(_entry), do: false
end
