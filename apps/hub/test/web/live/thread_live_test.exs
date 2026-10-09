defmodule PhotonWeb.ThreadLiveTest do
  @moduledoc """
  A project's threads, driven as a user would: starting one from the
  new-thread page, and its conversation (a command on a machine with its
  output streaming in, an image, the composer while it runs, Stop), next to
  Blip's panel on the same page; its state, Resolve, and its `ask_blip`
  questions.

  Threads run on the scripted model (`Photon.Threads.MockScript`). The test
  process connects as the machine `box` (`Photon.MachineOps.connect/2`), so
  an op started on it arrives here as `{:push_op, id}`, and the test answers
  for the node through `Photon.Machines.output/3` and `snapshot/3`.

  For questions, Blip is parked on a command on `box` (registered as a
  machine that never answers), so a thread's `ask blip:` question stays
  with Blip until the test passes it to the owner with
  `Photon.Questions.pass_tx/4`, as Blip's `ask_owner` does.
  """

  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Photon.Fixtures, only: [call: 3]

  alias Photon.{
    Assistant,
    Durable,
    MachineOps,
    Machines,
    Projects,
    Questions,
    Schedules,
    Skills,
    Threads
  }

  alias Photon.Durable.Tx
  alias Photon.Questions.Question
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

  defp thread_page(conn, project, %{id: id}), do: thread_page(conn, project, id)

  defp thread_page(conn, project, thread_id) do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/threads/#{thread_id}")
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
      assert has_element?(view, "#thread-state[data-state=running]")

      Machines.output("box", %{"id" => op_id, "stream" => "out", "text" => "notes.txt\n"}, %{})
      assert has_element?(view, "#{action}-tail pre", "notes.txt")

      {_pushes, _routes} = Machines.snapshot("box", completed(op_id, "ls", "notes.txt\n"), %{})
      await_entry(thread.id, &(&1.kind == "tool_result"), @wait)
      await_idle(thread.id)

      refute has_element?(view, "#{action}-tail")
      assert has_element?(view, "#{action}[data-status=done] summary", "Ran ls on box")
      assert has_element?(view, "#{action} details pre", "notes.txt")
      assert has_element?(view, "#thread-state[data-state=idle]")
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

      # The machine's last word on the canceled command says what it
      # printed, so a reload shows it too.
      canceled =
        MachineOps.snapshot(op_id, "canceled", %{
          "terminal_error" => "shell operation canceled",
          "result" => %{"out" => "tick 1\ntick 2\n", "err" => ""}
        })

      {_pushes, _routes} = Machines.snapshot("box", canceled, %{})
      reloaded = thread_page(conn, project, thread)
      assert has_element?(reloaded, "#{action}[data-status=stopped]")
      assert has_element?(reloaded, "#{action}-tail pre", ~r/tick 1\s+tick 2/)
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
      assert has_element?(view, "#thread-state[data-state=idle]")
      refute has_element?(view, "#thread-stop")
      refute has_element?(view, "#thread-composer-input[phx-mounted]")
      _run = busy!(thread.id)
      %{thread: thread, view: view}
    end

    test "a message waits, and can be withdrawn", %{thread: thread, view: view} do
      assert has_element?(view, "#thread-state[data-state=running]", "Running")
      refute has_element?(view, "#thread-resolve")
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
      assert has_element?(view, "#thread-state[data-state=idle]")
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
    assert has_element?(view, "#thread-state[data-state=idle]")
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

  describe "the title" do
    test "the owner renames the thread in place", %{conn: conn, project: project} do
      thread = idle_thread!(project, "Fix the pump")
      view = thread_page(conn, project, thread)
      assert has_element?(view, "#thread-title", "Fix the pump")
      refute has_element?(view, "#thread-rename-form")

      view |> element("#thread-rename") |> render_click()
      assert has_element?(view, ~s(#thread-title-input[value="Fix the pump"][phx-mounted]))

      view |> element("#thread-rename-cancel") |> render_click()
      assert has_element?(view, "#thread-title", "Fix the pump")

      view |> element("#thread-rename") |> render_click()
      view |> form("#thread-rename-form", thread: %{title: "  "}) |> render_submit()
      assert has_element?(view, "#thread-rename-form", "Give it a title.")

      view |> form("#thread-rename-form", thread: %{title: "Pump  check"}) |> render_submit()
      refute has_element?(view, "#thread-rename-form")
      assert has_element?(view, "#thread-title", "Pump check")
      assert has_element?(view, "#side-thread-#{thread.id}", "Pump check")
      assert page_title(view) =~ "Pump check"
      assert Threads.get(thread.id).title == "Pump check"
    end

    test "the header, the sidebar and Blip's chip follow a new title", %{
      conn: conn,
      project: project
    } do
      thread = idle_thread!(project, "Fix the pump")
      view = thread_page(conn, project, thread)
      blip = find_live_child(view, "blip")
      render_hook(blip, "page", %{"path" => ~p"/projects/garden/threads/#{thread.id}"})
      assert has_element?(blip, "#page-chip", "About Garden / Fix the pump")

      # As the model's title lands (Photon.Threads.Titling), or a rename elsewhere.
      {:ok, _thread} = Threads.rename(thread.id, "Pump check")
      _ = :sys.get_state(Photon.Durable.Store)

      assert has_element?(view, "#thread-title", "Pump check")
      assert has_element?(view, "#side-thread-#{thread.id}", "Pump check")
      assert has_element?(blip, "#page-chip", "About Garden / Pump check")
    end
  end

  describe "schedules and skills" do
    test "Schedule opens a new schedule for this thread", %{conn: conn, project: project} do
      thread = idle_thread!(project, "Fix the pump")
      view = thread_page(conn, project, thread)

      path = "/projects/garden/schedules/new?thread=#{thread.id}"
      assert has_element?(view, ~s(#thread-schedule[href="#{path}"]), "Schedule")
    end

    test "a scheduled prompt shows as Scheduled", %{conn: conn, project: project} do
      thread = idle_thread!(project, "Fix the pump")
      view = thread_page(conn, project, thread)

      {:ok, schedule} =
        Schedules.create({:project, project.id}, %{
          "prompt" => "Check the pump",
          "at" => DateTime.utc_now() |> DateTime.add(1, :hour) |> DateTime.to_iso8601(),
          "repeat" => "once",
          "target" => thread.id
        })

      assert Schedules.run_now(schedule.id) == {:ok, "sent"}
      await_idle(thread.id)

      [entry] =
        for %{kind: "user"} = entry <- Durable.entries(thread.id),
            entry.data["source"]["kind"] == "routine",
            do: entry

      assert has_element?(view, "#thread-entry-#{entry.id}", "Scheduled")
      assert has_element?(view, "#thread-entry-#{entry.id} p", "Check the pump")
      refute has_element?(view, "#thread-entry-#{entry.id} p", "[Scheduled]")
    end

    test "loading a skill shows its line", %{conn: conn, project: project} do
      {:ok, skill} =
        Skills.create(%{
          "name" => "pdf-forms",
          "description" => "Fill in PDF forms.",
          "instructions" => "Use the form's own field names."
        })

      :ok = Skills.enable(skill.id, {:project, project.id})
      thread = idle_thread!(project, "load skill pdf-forms")
      view = thread_page(conn, project, thread)

      [%{"id" => call_id}] =
        Message.tool_calls(await_entry(thread.id, &tool_calls?/1).data["message"])

      action = "#thread-action-#{call_id}"

      assert has_element?(
               view,
               "#{action}[data-status=done] summary",
               "Loaded the pdf-forms skill"
             )

      assert has_element?(view, "#{action} details", "Use the form's own field names.")
    end
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

  describe "the thread's state" do
    test "opening a finished thread marks it read, and its Home row goes", %{
      conn: conn,
      project: project
    } do
      thread = idle_thread!(project, "files")
      assert %{state: :unread} = Threads.state(thread.id)

      {:ok, home, _html} = live(conn, ~p"/")
      assert has_element?(home, "#unread-#{thread.id}")

      view = thread_page(conn, project, thread)
      assert has_element?(view, "#thread-state[data-state=idle]", "Done")
      assert %{state: :idle, thread: %{seen_at: %DateTime{}}} = Threads.state(thread.id)

      _ = :sys.get_state(Photon.Durable.Store)
      refute has_element?(home, "#unread-#{thread.id}")
    end

    test "a run that ends while the page is open is seen at once", %{
      conn: conn,
      project: project
    } do
      thread = idle_thread!(project, "files")
      view = thread_page(conn, project, thread)

      {:ok, _submission} = Threads.send(thread.id, "files")
      await_idle(thread.id)
      _ = :sys.get_state(Photon.Durable.Store)

      assert has_element?(view, "#thread-state[data-state=idle]", "Done")
      assert %{state: :idle} = Threads.state(thread.id)
    end

    test "Resolve and Reopen", %{conn: conn, project: project} do
      thread = idle_thread!(project, "fail: the pump is unplugged")
      view = thread_page(conn, project, thread)
      assert has_element?(view, "#thread-state[data-state=failed]", "Failed")
      assert has_element?(view, "#thread-state [data-mark=failed]")
      refute has_element?(view, "#thread-reopen")

      view |> element("#thread-resolve") |> render_click()
      assert has_element?(view, "#thread-state[data-state=idle]", "Resolved")
      refute has_element?(view, "#thread-resolve")
      assert %{resolved_at: %DateTime{}} = Threads.get(thread.id)

      view |> element("#thread-reopen") |> render_click()
      assert has_element?(view, "#thread-state[data-state=failed]", "Failed")
      assert has_element?(view, "#thread-resolve")
      refute has_element?(view, "#thread-reopen")
      assert %{resolved_at: nil} = Threads.get(thread.id)
    end

    test "a thread that ended asking the owner waits on them", %{conn: conn, project: project} do
      thread = idle_thread!(project, "ask me: which zone should I water first")
      view = thread_page(conn, project, thread)
      assert has_element?(view, "#thread-state[data-state=waiting]", "Waiting on you")
      assert has_element?(view, "#thread-composer")
    end

    test "a message from Blip is signed as Blip's", %{conn: conn, project: project} do
      thread = idle_thread!(project, "Fix the pump")
      view = thread_page(conn, project, thread)

      {:ok, _submission} = Threads.send(thread.id, "files", source: %{"kind" => "blip"})
      await_idle(thread.id)

      [mine, blips] = for %{kind: "user"} = entry <- Durable.entries(thread.id), do: entry
      assert has_element?(view, "#thread-message-#{blips.id}", "files")
      assert has_element?(view, "#thread-message-#{blips.id}-about", "From Blip")
      refute has_element?(view, "#thread-message-#{mine.id}-about")
    end
  end

  describe "a question to Blip" do
    setup %{project: project} do
      park_blip!()
      {thread, asked} = asking!(project, "what colour is the gate?")
      %{thread: thread, asked: asked}
    end

    test "while Blip has it, the page says so above and under the composer", %{
      conn: conn,
      project: project,
      thread: thread
    } do
      view = thread_page(conn, project, thread)

      assert has_element?(view, "#thread-state[data-state=asking]", "Asking Blip")
      assert has_element?(view, "#thread-asking-blip", "Asking Blip: what colour is the gate?")

      assert has_element?(
               view,
               "#thread-composer-note",
               "What you send here reaches the thread after Blip answers."
             )

      assert has_element?(view, "#thread-composer-input")
      assert has_element?(view, "#thread-stop")
      refute has_element?(view, "#thread-questions")
      refute has_element?(view, "#thread-resolve")

      # The ask_blip line, while the call waits.
      [%{"id" => call_id}] =
        Message.tool_calls(await_entry(thread, &tool_calls?/1).data["message"])

      assert has_element?(
               view,
               "#thread-action-#{call_id}[data-status=pending] summary",
               "Asking Blip: what colour is the gate?"
             )
    end

    test "once it's with the owner, they answer it in the composer's place", %{
      conn: conn,
      project: project,
      thread: thread,
      asked: asked
    } do
      view = thread_page(conn, project, thread)
      gate = pass!(asked, "What colour should the gate be?")
      _ = :sys.get_state(Photon.Durable.Store)

      assert has_element?(view, "#thread-state[data-state=waiting]", "Waiting on you")
      refute has_element?(view, "#thread-composer")
      refute has_element?(view, "#thread-asking-blip")
      refute has_element?(view, "#thread-composer-note")

      banner = "#thread-question-#{gate.id}"
      assert has_element?(view, banner, "Blip passed this on")
      assert has_element?(view, "#{banner}-text", "What colour should the gate be?")
      refute has_element?(view, "#{banner}-note")
      assert has_element?(view, "#{banner}-form #{banner}-answer")
      assert has_element?(view, "#{banner}-send")
      assert has_element?(view, "#thread-questions #thread-stop")

      view
      |> form("#{banner}-form", answer: %{text: "green"})
      |> render_submit(%{"question_id" => gate.id})

      refute has_element?(view, banner)
      assert %Question{status: "answered", answer: "green"} = Questions.get(gate.id)

      result = await_entry(thread, &(&1.kind == "tool_result" and &1.data["name"] == "ask_blip"))
      assert result.data["status"] == "ok"
      await_idle(thread)
      _ = :sys.get_state(Photon.Durable.Store)

      assert has_element?(view, "#thread-composer-input")
      refute has_element?(view, "#thread-questions")

      [%{"id" => call_id} | _calls] =
        Message.tool_calls(await_entry(thread, &tool_calls?/1).data["message"])

      assert has_element?(
               view,
               "#thread-action-#{call_id}[data-status=done] summary",
               "Asked Blip: what colour is the gate?"
             )
    end

    test "a refused answer shows under its form, in the owner's words", %{
      conn: conn,
      project: project,
      thread: thread,
      asked: asked
    } do
      gate = pass!(asked, "What colour should the gate be?")
      view = thread_page(conn, project, thread)
      banner = "#thread-question-#{gate.id}"

      view
      |> form("#{banner}-form", answer: %{text: "  "})
      |> render_submit(%{"question_id" => gate.id})

      assert has_element?(view, "#{banner}-error", "Write an answer.")
      error = view |> element("#{banner}-error") |> render()
      refute error |> LazyHTML.from_fragment() |> LazyHTML.text() =~ "q_"
      assert %Question{status: "with_owner"} = Questions.get(gate.id)
    end

    test "a question the hub passed on shows the thread's own words", %{
      conn: conn,
      project: project,
      thread: thread,
      asked: asked
    } do
      {:ok, _passed} = Durable.commit(&Questions.pass_tx(&1, asked.id, nil, :hub))
      view = thread_page(conn, project, thread)

      banner = "#thread-question-#{asked.id}"
      assert has_element?(view, "#{banner}-text", "what colour is the gate?")
      assert has_element?(view, "#{banner}-note", "In the thread's own words")
    end

    test "two questions with the owner get a banner and a form each", %{
      conn: conn,
      project: project,
      thread: thread,
      asked: asked
    } do
      # A second call in the same round, as a thread may make.
      task =
        Durable.create_task(%{
          kind: "test_ask",
          conversation_id: thread,
          waiting: %{"signal" => "never"}
        })

      {:ok, second} =
        Questions.ask(%{
          task_id: task.id,
          thread_id: thread,
          thread_title: Threads.get(thread).title,
          project_id: project.id,
          project_slug: project.slug,
          project_name: project.name,
          question: "how tall is the fence?"
        })

      first = pass!(asked, "What colour should the gate be?")
      second = pass!(second, "How tall should the fence be?")
      view = thread_page(conn, project, thread)

      assert ids(view, "#thread-questions [id^=thread-question-][id$=-form]") == [
               "thread-question-#{first.id}-form",
               "thread-question-#{second.id}-form"
             ]

      assert has_element?(
               view,
               "#thread-question-#{second.id}-text",
               "How tall should the fence be?"
             )

      assert has_element?(view, "#thread-question-#{second.id}-answer")

      # The questions scroll in their own area; Stop stays under it, in view.
      assert ids(view, "#thread-questions-list [id^=thread-question-][id$=-form]") == [
               "thread-question-#{first.id}-form",
               "thread-question-#{second.id}-form"
             ]

      assert has_element?(view, "#thread-questions #thread-stop")
      refute has_element?(view, "#thread-questions-list #thread-stop")

      # Enter sends an answer, as in the composer.
      assert has_element?(view, "#thread-question-#{first.id}-answer[phx-hook$=AnswerBox]")
    end
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

  # Parks Blip on a command that never finishes, so a thread's question
  # stays with Blip.
  defp park_blip! do
    fake_machine("box")
    {:ok, _parked} = Assistant.send("on box: $ sleep 1000")
    :ok = Questions.subscribe()
  end

  # Starts a thread that asks Blip `question`; returns its ID and the
  # question once it is asked.
  defp asking!(project, question) do
    {:ok, thread} = Threads.start(project.id, "ask blip: " <> question)
    thread_id = thread.id
    assert_receive {:questions_changed, ^thread_id}, @wait
    assert %{^thread_id => [asked]} = Questions.open_by_thread([thread_id])
    :ok = Threads.subscribe(thread_id)
    {thread_id, asked}
  end

  # As Blip's ask_owner: the question goes to the owner in Blip's words.
  defp pass!(question, wording) do
    {:ok, passed} = Durable.commit(&Questions.pass_tx(&1, question.id, wording, :blip))
    passed
  end

  defp ids(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))
  end

  defp tool_calls?(%{kind: "assistant", data: %{"message" => message}}),
    do: Message.tool_calls(message) != []

  defp tool_calls?(_entry), do: false
end
