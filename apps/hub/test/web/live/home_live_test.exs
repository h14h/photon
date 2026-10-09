defmodule PhotonWeb.HomeLiveTest do
  @moduledoc """
  The home page: what needs the owner across every project, what is running,
  what has gone quiet, and Blip's schedules, kept current as they change.

  Threads run on the scripted model (`Photon.Threads.MockScript`): `ask
  me:` ends asking the owner, `fail:` fails, `files` finishes, `ask blip:`
  asks Blip. A thread that stays running makes a `shell` call on `box`, a
  machine the test process plays and never answers. Blip is parked the
  same way, so a thread's question stays with Blip until the test passes
  it on with `Photon.Questions.pass_tx/4`, as Blip's `ask_owner` does.
  Facts that need days to pass (a thread gone quiet, one read long ago)
  are written onto the thread's row before the page mounts.

  Ambient mode is turned on with `Photon.Ambient.configure/1`, as a
  Settings save does; a firing skipped for consent is made with
  `Photon.Ambient.fire_tx/3`, and a stopped timer with its `on_fail/3`.
  """

  use PhotonWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Photon.{
    Ambient,
    Assistant,
    ChatGPT,
    Durable,
    Machines,
    Projects,
    Questions,
    Repo,
    Schedules,
    Settings,
    Signals,
    Threads
  }

  alias Photon.Ambient.Timer
  alias Photon.Durable.Tx
  alias Photon.Schedules.Routine
  alias Photon.Threads.Thread

  @moduletag :durable

  @four_days 4 * 24 * 3600

  defp home(conn) do
    {:ok, view, _html} = live(conn, ~p"/")
    view
  end

  defp project!(name \\ "Garden") do
    {:ok, project} = Projects.create(%{"purpose" => "Keep the #{name} going.", "name" => name})
    project
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

  # Starts a thread and waits until its run has ended; returns its ID.
  defp ended!(project, text) do
    {:ok, thread} = Threads.start(project.id, text)
    idle!(thread.id)
  end

  defp idle!(thread_id) do
    :ok = Threads.subscribe(thread_id)

    if Threads.busy?(thread_id),
      do: await_change(thread_id, fn _changes -> not Threads.busy?(thread_id) end)

    thread_id
  end

  # Waits until Blip has nothing running, so what is posted next starts
  # its run rather than queueing.
  defp blip_idle! do
    blip = Assistant.conversation_id()
    :ok = Durable.subscribe(blip)

    if Durable.busy?(blip),
      do: await_change(blip, fn _changes -> not Durable.busy?(blip) end)

    :ok
  end

  # Starts a thread whose run waits on a shell call on `box`; returns its ID.
  defp running!(project) do
    {:ok, thread} = Threads.start(project.id, "on box: $ sleep 1000")
    :ok = Threads.subscribe(thread.id)
    _call = await_entry(thread.id, &(&1.kind == "assistant"))
    thread.id
  end

  # Starts a thread that asks Blip `question`; returns it and its question
  # once it is asked.
  defp asking!(project, question) do
    {:ok, thread} = Threads.start(project.id, "ask blip: " <> question)
    thread_id = thread.id
    assert_receive {:questions_changed, ^thread_id}, 5_000
    assert %{^thread_id => [asked]} = Questions.open_by_thread([thread_id])
    {thread.id, asked}
  end

  # As Blip's ask_owner: the question goes to the owner in Blip's words.
  defp pass!(question, wording) do
    {:ok, passed} = Durable.commit(&Questions.pass_tx(&1, question.id, wording, :blip))
    passed
  end

  # Moves a thread's recorded times back by four days.
  defp age!(thread_id, fields) do
    at = DateTime.add(DateTime.utc_now(), -@four_days, :second)

    {1, _rows} =
      Repo.update_all(from(t in Thread, where: t.id == ^thread_id),
        set: Enum.map(fields, &{&1, at})
      )

    :ok
  end

  # The commit that made the state the test waited for has broadcast once
  # the store has handled it; then the page has its messages queued before
  # this render.
  defp settled(view) do
    _ = :sys.get_state(Photon.Durable.Store)
    render(view)
  end

  defp ids(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))
  end

  test "is Home, marked in the sidebar", %{conn: conn} do
    view = home(conn)
    assert has_element?(view, "#home-heading", "Home")
    assert has_element?(view, "#nav-home[aria-current=page]")
    refute has_element?(view, "#nav-activity[aria-current]")
    assert page_title(view) =~ "Home"
  end

  describe "with no projects" do
    test "says how to start, and to add a machine while there is none", %{conn: conn} do
      view = home(conn)

      assert has_element?(
               view,
               "#home-start",
               "Start a project for work that takes more than one message"
             )

      assert has_element?(view, "#home-new-project[href='/projects/new']", "Start a project")
      assert has_element?(view, "#home-add-machine[href='/nodes']")
      assert has_element?(view, "#home-summary", "Nothing needs you right now.")
      refute has_element?(view, "#needs-you")
      refute has_element?(view, "#running")
      assert has_element?(view, "#schedules")
    end

    test "doesn't ask for a machine once there is one", %{conn: conn} do
      fake_machine("box")
      view = home(conn)

      assert has_element?(view, "#home-start")
      refute has_element?(view, "#home-add-machine")
    end
  end

  describe "the sections" do
    test "with nothing going on, say so", %{conn: conn} do
      _project = project!()
      view = home(conn)

      refute has_element?(view, "#home-start")

      assert has_element?(
               view,
               "#nothing-needs-you",
               "Nothing needs you. Blip will say when something does."
             )

      refute has_element?(view, "#waiting")
      refute has_element?(view, "#failed")
      refute has_element?(view, "#unread")
      assert has_element?(view, "#no-running", "Nothing running.")
      refute has_element?(view, "#quiet")
      assert has_element?(view, "#home-summary", "Nothing needs you right now.")
    end

    test "list each thread where it belongs", %{conn: conn} do
      project = project!()
      park_blip!()

      running = running!(project)
      {asking, _asked} = asking!(project, "which deploy branch?")
      {with_owner, gate} = asking!(project, "what colour is the gate?")
      gate = pass!(gate, "What colour should the gate be?")
      waiting = ended!(project, "ask me: which zone should I water first")
      failed = ended!(project, "fail: the pump is unplugged")
      unread = ended!(project, "files")

      stopped = running!(project)
      :ok = Threads.stop(stopped)
      idle!(stopped)
      :ok = age!(stopped, [:active_at, :last_run_ended_at])

      read = ended!(project, "files")
      :ok = Threads.mark_seen(read)
      :ok = age!(read, [:active_at, :last_run_ended_at, :seen_at])

      view = home(conn)

      # The thread with a question with the owner, the one that ended
      # asking, the failed one and the unread one.
      assert has_element?(view, "#home-summary", "4 things need you.")
      refute has_element?(view, "#nothing-needs-you")

      # Waiting on you: the question with Blip's wording and its form, and
      # the thread that asked, with Open and Resolve.
      assert ids(view, "#waiting-list > *") == ["question-#{gate.id}", "waiting-#{waiting}"]
      assert has_element?(view, "#question-#{gate.id}-text", "What colour should the gate be?")

      assert has_element?(
               view,
               "#question-#{gate.id}-thread[href='/projects/garden/threads/#{with_owner}']"
             )

      assert has_element?(view, "#question-#{gate.id}-project[href='/projects/garden']", "Garden")
      assert has_element?(view, "#question-#{gate.id}-form #question-#{gate.id}-answer")
      assert has_element?(view, "#question-#{gate.id}-send")
      refute has_element?(view, "#question-#{gate.id}-note")
      refute has_element?(view, "#waiting-#{with_owner}")

      assert has_element?(view, "#waiting-#{waiting}-detail", "which zone should I water first?")

      assert has_element?(
               view,
               "#waiting-#{waiting}-open[href='/projects/garden/threads/#{waiting}']"
             )

      assert has_element?(view, "#waiting-#{waiting}-resolve")

      assert ids(view, "#failed-list > *") == ["failed-#{failed}"]
      assert has_element?(view, "#failed-#{failed}-detail", "the pump is unplugged")
      assert has_element?(view, "#failed-#{failed}-resolve")

      assert ids(view, "#unread-list > *") == ["unread-#{unread}"]
      assert has_element?(view, "#unread-#{unread}-at")
      assert has_element?(view, "#mark-all-read")

      # Running: the thread at work, then the one waiting on Blip.
      assert ids(view, "#running-list > [id^=running-]") == [
               "running-#{running}",
               "running-#{asking}"
             ]

      assert has_element?(view, "#running-#{running}[data-state=running]", "Running since")
      assert has_element?(view, "#running-#{asking}[data-state=asking]")

      assert has_element?(
               view,
               "#running-#{asking}-detail",
               "Waiting on Blip: which deploy branch?"
             )

      assert has_element?(view, "#running-#{asking} [data-mark=asking]")

      assert ids(view, "#quiet-list > *") == ["quiet-#{stopped}"]
      assert has_element?(view, "#quiet-#{stopped}-detail", "Stopped")
      assert has_element?(view, "#quiet-#{stopped}-resolve")

      # Done, read and old is in no section.
      refute has_element?(view, "[id$='-#{read}']")
    end

    test "a question the hub passed on shows the thread's own words", %{conn: conn} do
      project = project!()
      park_blip!()
      {_thread, asked} = asking!(project, "which deploy branch?")
      {:ok, _passed} = Durable.commit(&Questions.pass_tx(&1, asked.id, nil, :hub))

      view = home(conn)
      assert has_element?(view, "#question-#{asked.id}-text", "which deploy branch?")
      assert has_element?(view, "#question-#{asked.id}-note", "In the thread's own words")
      # Enter sends the answer, as in the composer.
      assert has_element?(view, "#question-#{asked.id}-answer[phx-hook$=AnswerBox]")
    end

    test "a question asked from another process appears, and moves when it is passed on", %{
      conn: conn
    } do
      project = project!()
      park_blip!()
      view = home(conn)
      assert has_element?(view, "#no-running")

      {thread, asked} = asking!(project, "which deploy branch?")
      _ = settled(view)
      assert has_element?(view, "#running-#{thread}[data-state=asking]")
      refute has_element?(view, "#waiting")

      _passed = pass!(asked, "Which branch should we deploy?")
      _ = settled(view)
      assert has_element?(view, "#question-#{asked.id}", "Which branch should we deploy?")
      refute has_element?(view, "#running-#{thread}")
      assert has_element?(view, "#home-summary", "1 thing needs you.")
    end
  end

  describe "answering a question" do
    setup do
      project = project!()
      park_blip!()
      {thread, asked} = asking!(project, "what colour is the gate?")

      %{
        project: project,
        thread: thread,
        question: pass!(asked, "What colour should the gate be?")
      }
    end

    test "sends the answer to the thread, and the row goes", %{
      conn: conn,
      thread: thread,
      question: question
    } do
      view = home(conn)
      :ok = Durable.subscribe(thread)

      view
      |> form("#question-#{question.id}-form", answer: %{text: "green"})
      |> render_submit(%{"question_id" => question.id})

      refute has_element?(view, "#question-#{question.id}")

      assert %{status: "answered", answer: "green", answered_by: "owner"} =
               Questions.get(question.id)

      result = await_entry(thread, &(&1.kind == "tool_result" and &1.data["name"] == "ask_blip"))
      assert result.data["status"] == "ok"
    end

    test "keeps what was typed when the page reads the board again", %{
      conn: conn,
      project: project,
      question: question
    } do
      view = home(conn)

      view
      |> form("#question-#{question.id}-form", answer: %{text: "gre"})
      |> render_change(%{"question_id" => question.id})

      # Another thread finishing makes the page read the board again.
      _other = ended!(project, "files")
      _ = settled(view)

      assert has_element?(view, "#unread")
      assert has_element?(view, "#question-#{question.id}-answer", "gre")
    end

    test "shows a refusal under the form, in the owner's words", %{conn: conn, question: question} do
      view = home(conn)

      view
      |> form("#question-#{question.id}-form", answer: %{text: "  "})
      |> render_submit(%{"question_id" => question.id})

      assert has_element?(view, "#question-#{question.id}-error", "Write an answer.")

      view
      |> form("#question-#{question.id}-form", answer: %{text: String.duplicate("a", 4_001)})
      |> render_submit(%{"question_id" => question.id})

      assert has_element?(
               view,
               "#question-#{question.id}-error",
               "Keep the answer under 4,000 characters."
             )

      error = view |> element("#question-#{question.id}-error") |> render()
      refute error |> LazyHTML.from_fragment() |> LazyHTML.text() =~ "q_"
      assert %{status: "with_owner"} = Questions.get(question.id)

      # The text stays to be fixed.
      assert has_element?(view, "#question-#{question.id}-answer", "aaaa")
    end
  end

  describe "clearing the lists" do
    test "Resolve takes a failed thread off", %{conn: conn} do
      project = project!()
      failed = ended!(project, "fail: the pump is unplugged")
      view = home(conn)
      assert has_element?(view, "#home-summary", "1 thing needs you.")

      view |> element("#failed-#{failed}-resolve") |> render_click()

      refute has_element?(view, "#failed")
      assert has_element?(view, "#nothing-needs-you")
      assert has_element?(view, "#home-summary", "Nothing needs you right now.")
      assert %Thread{resolved_at: %DateTime{}} = Threads.get(failed)
    end

    test "Resolve takes a thread that asked off", %{conn: conn} do
      project = project!()
      waiting = ended!(project, "ask me: which zone should I water first")
      view = home(conn)

      view |> element("#waiting-#{waiting}-resolve") |> render_click()
      refute has_element?(view, "#waiting")
    end

    test "Resolve takes a quiet thread off, and the section goes", %{conn: conn} do
      fake_machine("box")
      project = project!()
      stopped = running!(project)
      :ok = Threads.stop(stopped)
      idle!(stopped)
      :ok = age!(stopped, [:active_at, :last_run_ended_at])
      view = home(conn)
      assert has_element?(view, "#quiet-#{stopped}")

      view |> element("#quiet-#{stopped}-resolve") |> render_click()
      refute has_element?(view, "#quiet")
    end

    test "Mark all read empties Finished and says how many", %{conn: conn} do
      project = project!()
      first = ended!(project, "files")
      second = ended!(project, "files")
      view = home(conn)
      assert ids(view, "#unread-list > *") == ["unread-#{second}", "unread-#{first}"]

      view |> element("#mark-all-read") |> render_click()

      refute has_element?(view, "#unread")
      assert has_element?(view, "#flash-info", "Marked 2 threads read.")
      assert has_element?(view, "#nothing-needs-you")
    end
  end

  describe "Blip's schedules" do
    setup %{conn: conn}, do: %{view: home(conn)}

    # One of Blip's schedules, as its `schedule` tool makes it.
    defp blip_schedule!(args, request_id) do
      now = System.system_time(:millisecond)

      {:ok, schedule} =
        Durable.commit(
          &Schedules.tool_schedule_tx(
            &1,
            {:blip, Assistant.conversation_id()},
            args,
            %{asked_by: "owner", request_id: request_id, now: now}
          )
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

  describe "ambient mode" do
    defp ambient_on!, do: :ok = Ambient.configure(%{"ambient" => "true"})

    test "says nothing while it is on and healthy", %{conn: conn} do
      _project = project!()
      ambient_on!()
      view = home(conn)

      refute has_element?(view, "#ambient-consent")
      refute has_element?(view, "#ambient-stopped")
      refute has_element?(view, "#ambient-settings")
    end

    test "warns when a timer stopped, until Settings is saved", %{conn: conn} do
      ambient_on!()
      view = home(conn)
      refute has_element?(view, "#ambient-stopped")

      # As the Scheduler fails a timer whose step raised.
      task = Durable.task(Signals.ambient_doc()["digest_task_id"])

      :ok =
        Durable.commit(fn tx ->
          _failed = Tx.finish(tx, task, "failed", %{"status" => "failed", "reason" => "boom"})
          Timer.on_fail(task, "boom", tx)
        end)

      _ = render(view)

      assert has_element?(
               view,
               "#ambient-stopped",
               "Ambient mode stopped after an error. Save settings to start it again."
             )

      assert has_element?(view, "#ambient-settings[href='/settings']", "Settings")
      refute has_element?(view, "#ambient-consent")

      # A Save arms a new timer, which clears it.
      :ok = Ambient.configure(%{})
      _ = render(view)
      refute has_element?(view, "#ambient-stopped")
    end

    test "warns when a firing skipped for consent, until schedules may use the plan", %{
      conn: conn
    } do
      ambient_on!()
      view = home(conn)

      firing = %{
        thinks?: true,
        allowed?: false,
        key: "digest:test:0",
        now: System.system_time(:millisecond)
      }

      assert %{outcome: "skipped_consent"} =
               Durable.commit(&Ambient.fire_tx(&1, "digest", firing))

      _ = render(view)

      assert has_element?(
               view,
               "#ambient-consent",
               "Digests and reviews are skipping: schedules can't use your plan while you're away."
             )

      assert has_element?(view, "#ambient-settings[href='/settings']")

      # The Settings page's Save writes the file first, which announces
      # the change; the warning goes with it.
      _settings = Settings.save(%{"scheduled_work" => "true"})
      _ = render(view)
      refute has_element?(view, "#ambient-consent")
    end

    test "warns while digests skip because Blip isn't signed in, until it is again", %{
      conn: conn
    } do
      ambient_on!()
      Application.put_env(:photon, :mock_model, false)
      on_exit(fn -> Application.put_env(:photon, :mock_model, true) end)
      view = home(conn)

      assert %{outcome: "skipped_model"} = Ambient.digest_now()
      _ = render(view)

      assert has_element?(
               view,
               "#ambient-signed-out",
               "Digests and reviews are skipping: Blip isn't signed in to ChatGPT."
             )

      assert has_element?(view, "#ambient-settings[href='/settings']")
      refute has_element?(view, "#ambient-consent")

      # Blip can think again (here, the scripted model): the next ChatGPT
      # change the page hears takes the warning down.
      Application.put_env(:photon, :mock_model, true)
      send(view.pid, {:chatgpt_changed, ChatGPT.status()})
      _ = render(view)
      refute has_element?(view, "#ambient-signed-out")
    end

    test "a row raised in Blip's review says so, and not before", %{conn: conn} do
      fake_machine("box")
      project = project!()
      ambient_on!()

      stopped = running!(project)
      :ok = Threads.stop(stopped)
      idle!(stopped)
      failed = ended!(project, "fail: the pump is unplugged")
      waiting = ended!(project, "ask me: which zone should I water first")
      unread = ended!(project, "files")

      for id <- [stopped, failed, waiting, unread],
          do: :ok = age!(id, [:active_at, :last_run_ended_at])

      view = home(conn)
      assert has_element?(view, "#quiet-#{stopped}")
      assert has_element?(view, "#failed-#{failed}")
      assert has_element?(view, "#waiting-#{waiting}")
      refute has_element?(view, "[id$='-reviewed']")

      # The failure and the question reached Blip as updates; the review
      # is sent once Blip is done with them, not queued behind them.
      blip_idle!()
      assert %{outcome: "sent", count: 3} = Ambient.review_now()
      %Thread{reviewed_at: reviewed_at} = Threads.get(stopped)
      _ = settled(view)

      for row <- ["quiet-#{stopped}", "failed-#{failed}", "waiting-#{waiting}"] do
        assert has_element?(view, "##{row}-reviewed", "In Blip's review")
        iso = reviewed_at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        assert has_element?(view, ~s(##{row}-reviewed-at[datetime="#{iso}"]))
      end

      # Unread work isn't in a review; it is the digest's.
      refute has_element?(view, "#unread-#{unread}-reviewed")
    end
  end
end
