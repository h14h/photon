defmodule Photon.ThreadsTest do
  @moduledoc """
  `Photon.Threads` through its API, on the durable harness with the
  scripted model (`Photon.Threads.MockScript`). A thread that stays busy
  runs a `shell` call on a stand-in machine: the test process registers
  under the machine's name and never answers, so the call waits until it
  is stopped. The rules themselves are covered in `test/core/threads/`.
  """

  use Photon.DataCase, async: false

  @moduletag :durable

  alias Photon.{Assistant, Projects, Settings, Signals, Threads}
  alias Photon.Durable.{Conversation, Submission}
  alias Photon.Signals.DigestItem
  alias Photon.Threads.Thread

  import Ecto.Query, only: [from: 2]

  setup do
    {:ok, project} =
      Projects.create(%{"purpose" => "Keep the garden watered.", "name" => "Garden"})

    %{project: project}
  end

  # Stands in for a connected machine that takes commands and never
  # answers, so a shell call on it keeps its thread running.
  defp fake_machine(name) do
    {:ok, _owner} =
      Registry.register(Photon.MachineRegistry, name, %{
        "platform" => "test",
        "workspace" => "/w",
        "version" => "0",
        "capabilities" => ["ops:2"]
      })
  end

  defp start!(project, text) do
    {:ok, thread} = Threads.start(project.id, text)
    thread
  end

  # Starts a thread and waits until it has answered; returns its ID.
  defp idle_thread!(project, text), do: idle!(start!(project, text).id)

  # Waits until the thread has no run in progress.
  defp idle!(thread_id) do
    :ok = Threads.subscribe(thread_id)

    if Threads.busy?(thread_id),
      do: await_change(thread_id, fn _changes -> not Threads.busy?(thread_id) end)

    thread_id
  end

  # Starts a thread whose run waits on a shell call on `box`.
  defp running!(project, title) do
    thread = start!(project, "on box: $ sleep 1000 # #{title}")
    :ok = Threads.subscribe(thread.id)
    await_entry(thread.id, &(&1.kind == "assistant"))
    assert Threads.busy?(thread.id)
    thread
  end

  describe "start/2" do
    test "makes the row, the conversation and the first message, and the thread answers", %{
      project: project
    } do
      :ok = Projects.subscribe()

      assert {:ok, %Thread{id: id, title: "Check the valves", project_id: project_id}} =
               Threads.start(project.id, "Check the valves\nzone 2 sticks")

      assert project_id == project.id
      assert_receive {:projects_changed, ^project_id}

      assert %Conversation{profile: "thread", title: "Check the valves"} =
               Durable.conversation(id)

      assert %Thread{active_at: %DateTime{}} = Threads.get(id)
      assert [%{kind: "user"} = first | _] = Durable.entries(id)
      assert first.data["source"] == %{"kind" => "user"}

      :ok = Threads.subscribe(id)
      answer = await_entry(id, &(&1.kind == "assistant"))
      assert PhotonCore.Message.text_of(answer.data["message"]) =~ "scripted model"
      assert Threads.latest_answer(idle!(id)) =~ "scripted model"
    end

    test "refuses a blank first message and makes nothing", %{project: project} do
      :ok = Projects.subscribe()
      assert Threads.start(project.id, "  \n ") == {:error, :blank}
      assert Threads.list(project.id) == []
      assert Repo.aggregate(Conversation, :count) == 0
      refute_received {:projects_changed, _}
    end

    test "refuses a project that doesn't exist" do
      assert Threads.start("p_missing", "hello") == {:error, :not_found}
      assert Repo.aggregate(Conversation, :count) == 0
    end
  end

  describe "send/3" do
    test "submits, moves active_at and announces the project", %{project: project} do
      older = idle_thread!(project, "first")
      newer = idle_thread!(project, "second")
      assert Enum.map(Threads.list(project.id), & &1.id) == [newer, older]

      before = Threads.get(older).active_at
      :ok = Projects.subscribe()

      assert {:ok, %Submission{} = submission} = Threads.send(older, "hello again")
      project_id = project.id
      assert_receive {:projects_changed, ^project_id}
      assert DateTime.after?(Threads.get(older).active_at, before)
      assert Enum.map(Threads.list(project.id), & &1.id) == [older, newer]

      assert %Submission{status: "done"} = await_settled(older, submission.id)
    end

    test "refuses a blank message and a missing thread", %{project: project} do
      thread = start!(project, "first")
      assert Threads.send(thread.id, " ") == {:error, :blank}
      assert Threads.send("c_missing", "hello") == {:error, :not_found}
    end

    test "with when_busy reject, a busy thread refuses and stays where it was", %{
      project: project
    } do
      fake_machine("box")
      thread = running!(project, "busy")
      before = Threads.get(thread.id).active_at

      assert Threads.send(thread.id, "machines", when_busy: "reject") == {:error, :busy}
      assert Threads.get(thread.id).active_at == before
      Threads.stop(thread.id)
    end
  end

  describe "start_tx/4 and send_tx/4, inside a schedule's commit" do
    @source %{"kind" => "routine", "schedule_id" => "sc_backups"}

    defp submissions(request_id),
      do: Repo.all(from(s in Submission, where: s.request_id == ^request_id))

    test "start_tx/4 starts a thread with the schedule as the first message's source, once", %{
      project: project
    } do
      :ok = Projects.subscribe()
      opts = [source: @source, request_id: "schedule:sc_backups:t_1:0"]
      start = &Threads.start_tx(&1, project.id, "[Scheduled] Check the backups", opts)

      # Titled by the prompt (section 3.2), without the "[Scheduled] " in front.
      assert {:ok, %Thread{id: id, title: "Check the backups"}} = Durable.commit(start)

      project_id = project.id
      assert_receive {:projects_changed, ^project_id}
      assert [%{kind: "user"} = first | _] = Durable.entries(id)
      assert first.data["source"] == @source

      assert [%Submission{conversation_id: ^id} = submission] =
               submissions("schedule:sc_backups:t_1:0")

      assert submission.content["source"] == @source

      assert {:ok, %Thread{id: ^id}} = Durable.commit(start)
      assert [%Thread{id: ^id}] = Threads.list(project.id)
      assert [%Submission{id: same}] = submissions("schedule:sc_backups:t_1:0")
      assert same == submission.id
      idle!(id)
    end

    test "start_tx/4 refuses a blank message and a missing project, and the commit goes on", %{
      project: project
    } do
      assert Durable.commit(fn tx ->
               {Threads.start_tx(tx, project.id, " ", source: @source),
                Threads.start_tx(tx, "p_missing", "hello")}
             end) == {{:error, :blank}, {:error, :not_found}}

      assert Threads.list(project.id) == []
      assert Repo.aggregate(Conversation, :count) == 0
    end

    test "send_tx/4 sends with the schedule as source, and a repeated request ID sends once", %{
      project: project
    } do
      thread_id = idle_thread!(project, "first")
      opts = [source: @source, request_id: "schedule:sc_backups:t_1:1"]
      send = &Threads.send_tx(&1, thread_id, "[Scheduled] machines", opts)

      assert {:ok, %Submission{} = submission} = Durable.commit(send)
      assert submission.content["source"] == @source
      assert {:ok, %Submission{id: same}} = Durable.commit(send)
      assert same == submission.id
      assert [_one] = submissions("schedule:sc_backups:t_1:1")

      assert %Submission{status: "done", entry_id: entry_id} =
               await_settled(thread_id, submission.id)

      assert [%{id: ^entry_id}] =
               Enum.filter(Durable.entries(thread_id), &(&1.data["source"] == @source))

      assert Durable.commit(&Threads.send_tx(&1, "c_missing", "hello")) == {:error, :not_found}
      assert Durable.commit(&Threads.send_tx(&1, thread_id, "")) == {:error, :blank}
    end

    test "a scheduled prompt queued on a busy thread is withdrawn by stop/1", %{project: project} do
      fake_machine("box")
      thread = running!(project, "busy")
      opts = [source: @source, request_id: "schedule:sc_backups:t_1:2"]

      assert {:ok, %Submission{status: "queued"} = queued} =
               Durable.commit(&Threads.send_tx(&1, thread.id, "[Scheduled] machines", opts))

      assert Threads.stop(thread.id) == :ok
      idle!(thread.id)
      assert Repo.get(Submission, queued.id).status == "withdrawn"
    end
  end

  describe "sidebar/1" do
    test "groups threads under their projects, newest first, five a project, with the rest counted",
         %{project: garden} do
      {:ok, shed} = Projects.create(%{"purpose" => "Tidy the shed."})

      threads = for n <- 1..7, do: idle_thread!(garden, "thread #{n}")
      shed_thread = idle_thread!(shed, "sort the tools")

      assert [
               %{project: %{slug: "garden", name: "Garden"}, threads: listed, more: 2},
               %{project: %{slug: "tidy-the-shed"}, threads: [shed_row], more: 0}
             ] = Threads.sidebar(5)

      assert Enum.map(listed, & &1.id) == threads |> Enum.reverse() |> Enum.take(5)

      assert Enum.map(listed, & &1.title) == [
               "thread 7",
               "thread 6",
               "thread 5",
               "thread 4",
               "thread 3"
             ]

      assert Enum.all?(listed, &(&1.running? == false))

      assert shed_row == %{
               id: shed_thread,
               title: "sort the tools",
               running?: false,
               state: :unread
             }
    end

    test "lists a running thread past the five, and a project with no threads", %{
      project: garden
    } do
      fake_machine("box")
      {:ok, _empty} = Projects.create(%{"purpose" => "Plan the trip.", "name" => "Trip"})

      running = running!(garden, "oldest")
      newer = for n <- 1..6, do: idle_thread!(garden, "thread #{n}")

      assert [%{threads: listed, more: 1}, %{project: %{name: "Trip"}, threads: [], more: 0}] =
               Threads.sidebar(5)

      assert Enum.map(listed, & &1.id) == Enum.take(Enum.reverse(newer), 5) ++ [running.id]
      assert [%{running?: true}] = Enum.filter(listed, & &1.running?)

      Threads.stop(running.id)
      idle!(running.id)

      assert [%{threads: listed, more: 2}, _trip] = Threads.sidebar(5)
      refute running.id in Enum.map(listed, & &1.id)
    end
  end

  describe "running and stopping" do
    test "running/1 holds a thread while its run is live, and stop/1 ends it", %{
      project: project
    } do
      fake_machine("box")
      thread = running!(project, "stop me")
      idle = idle_thread!(project, "hello")

      assert Threads.running([thread.id, idle]) == MapSet.new([thread.id])

      {:ok, queued} = Threads.send(thread.id, "machines")
      assert [%Submission{id: queued_id}] = Threads.queued(thread.id)
      assert queued_id == queued.id

      assert Threads.stop(thread.id) == :ok
      idle!(thread.id)

      assert Threads.running([thread.id, idle]) == MapSet.new()
      assert Threads.queued(thread.id) == []
      assert Repo.get(Submission, queued.id).status == "withdrawn"
    end

    test "withdraw/1 takes back a queued message", %{project: project} do
      fake_machine("box")
      thread = running!(project, "busy")
      {:ok, queued} = Threads.send(thread.id, "machines")

      assert Threads.withdraw(queued.id) == :ok
      assert Threads.queued(thread.id) == []
      Threads.stop(thread.id)
    end
  end

  describe "the thread profile" do
    test "has the machine tools, the four context-file tools, load_skill and ask_blip, nothing else",
         %{
           project: project
         } do
      thread = start!(project, "hello")
      conversation = Durable.conversation(thread.id)

      assert conversation |> Threads.tools() |> Enum.map(& &1.name()) |> Enum.sort() ==
               Enum.sort(~w(shell view_image list_machines list_context_files read_context_file
                   write_context_file edit_context_file load_skill ask_blip))

      # None of Blip's own (they share only the machine tools): a thread
      # can't schedule anything or touch Blip's memory.
      blips = Assistant.tools(nil) -- Photon.MachineTools.tools()
      assert Threads.tools(conversation) -- blips == Threads.tools(conversation)
    end

    test "works in the project's folder, and searches the web with the model in Settings", %{
      project: project
    } do
      thread = start!(project, "hello")
      conversation = Durable.conversation(thread.id)

      assert Threads.workdir(conversation) == "garden"

      llm = Threads.llm(conversation)
      assert llm.config.hosted_tools == [%{"type" => "web_search"}]
      assert llm.config.script == Photon.Threads.MockScript
      assert llm.model == Settings.model(Settings.load())
      assert llm.cache_key == thread.id
    end

    test "the system prompt has the project and leaves out what Settings and memory hold", %{
      project: project
    } do
      Settings.save(%{
        "provider" => "mock",
        "user_name" => "Henry",
        "timezone" => "Europe/London",
        "instructions" => "Always answer in French."
      })

      Assistant.put_memory("The NAS is called mp1.")

      thread = start!(project, "hello")
      prompt = Threads.system_prompt(Durable.conversation(thread.id))

      assert prompt =~ "Name: Garden"
      assert prompt =~ "Keep the garden watered."
      assert prompt =~ "`<workspace>/garden`"

      # It names Blip only as the one ask_blip asks, never in Blip's voice.
      for text <- ["Henry", "Europe/London", "French", "mp1", "You are Blip"],
          do: refute(prompt =~ text, "the prompt has #{inspect(text)}")
    end

    test "a conversation that isn't a thread has no project" do
      conversation = Durable.create_conversation("thread", %{title: "orphan"})

      assert_raise RuntimeError, ~r/project no longer exists/, fn ->
        Threads.workdir(conversation)
      end

      assert_raise RuntimeError, ~r/project no longer exists/, fn ->
        Threads.system_prompt(conversation)
      end
    end
  end

  describe "titles" do
    setup do
      Application.put_env(:photon, Threads, auto_title: true)
      on_exit(fn -> Application.put_env(:photon, Threads, auto_title: false) end)
    end

    # The thread's title task, as stored now.
    defp title_task(thread_id) do
      Repo.one!(
        from(t in Durable.TaskRecord,
          where: t.conversation_id == ^thread_id and t.kind == "thread_title"
        )
      )
    end

    # Waits until the thread's title task has finished.
    defp titled!(thread_id) do
      :ok = Threads.subscribe(thread_id)

      if title_task(thread_id).status != "done" do
        await_change(thread_id, fn changes ->
          Enum.any?(changes.tasks, &(&1.kind == "thread_title" and &1.status == "done"))
        end)
      end

      Threads.get(thread_id)
    end

    test "after its first run, the model names the thread, and the pages hear of it", %{
      project: project
    } do
      fake_machine("box")
      :ok = Projects.subscribe()
      thread = running!(project, "pump")
      project_id = project.id
      assert_receive {:projects_changed, ^project_id}

      # Background work waiting on the run: it doesn't make the thread busy.
      assert %{status: "waiting", background: true} = title_task(thread.id)
      assert thread.title == "on box: $ sleep 1000 # pump"

      :ok = Threads.stop(thread.id)
      assert %Thread{title: "Run sleep on box"} = titled!(thread.id)
      assert_receive {:projects_changed, ^project_id}
      refute Threads.busy?(thread.id)
    end

    test "a title the owner gave the thread meanwhile stays", %{project: project} do
      fake_machine("box")
      thread = running!(project, "pump")
      assert {:ok, %Thread{title: "Pump check"}} = Threads.rename(thread.id, " Pump\ncheck ")

      :ok = Threads.stop(thread.id)
      assert %Thread{title: "Pump check"} = titled!(thread.id)
    end

    test "without a model the thread keeps its first title", %{project: project} do
      Photon.ChatGPTStub.reset!()
      Application.put_env(:photon, :mock_model, false)
      on_exit(fn -> Application.put_env(:photon, :mock_model, true) end)

      thread = start!(project, "Check the valves")
      assert %Thread{title: "Check the valves"} = titled!(thread.id)
    end

    test "rename/2 refuses a blank title and a missing thread", %{project: project} do
      id = idle_thread!(project, "Check the valves")
      assert Threads.rename(id, "  ") == {:error, :blank}
      assert Threads.rename("c_missing", "Valves") == {:error, :not_found}
      assert Threads.get(id).title == "Check the valves"
    end
  end

  describe "latest_answer/1" do
    test "skips newer messages that only call tools", %{project: project} do
      id = idle_thread!(project, "Check the valves")
      call = %{"id" => "c9", "name" => "shell", "arguments" => ~s({"machine":"box"})}

      Durable.commit(
        &Durable.Tx.append(&1, id, "assistant", %{
          "message" => PhotonCore.Message.assistant("The zone 2 valve is stuck open.")
        })
      )

      Durable.commit(
        &Durable.Tx.append(&1, id, "assistant", %{
          "message" => PhotonCore.Message.assistant("", [call])
        })
      )

      assert Threads.latest_answer(id) == "The zone 2 valve is stuck open."
    end

    test "is nil when no message has text" do
      assert Threads.latest_answer("c_missing") == nil
    end
  end

  describe "images" do
    test "image/3 finds nothing outside a thread's conversation", %{project: project} do
      thread = start!(project, "hello")
      [entry | _] = Durable.entries(thread.id)

      assert Threads.image(thread.id, entry.id, 0) == :error
      assert Threads.image(Assistant.conversation_id(), entry.id, 0) == :error
      assert Threads.image("c_missing", entry.id, 0) == :error
    end
  end

  describe "digest items" do
    defp ambient!(on?) do
      _doc = Durable.commit(&Signals.put_ambient_doc_tx(&1, %{"on" => on?}))
      :ok
    end

    # The items of `kinds`, oldest first, as {kind, thread, project}.
    defp items(kinds) do
      query =
        from(i in DigestItem, where: i.kind in ^kinds, order_by: [asc: i.inserted_at, asc: i.id])

      for item <- Repo.all(query), do: {item.kind, item.thread_id, item.project_id}
    end

    test "with ambient mode on, the owner's start and Resolve each collect one", %{
      project: project
    } do
      ambient!(true)
      id = idle_thread!(project, "hello")
      assert [{"thread_started", id, project.id}] == items(["thread_started", "resolved"])

      assert Threads.resolve(id) == :ok
      assert Threads.reopen(id) == :ok
      assert Threads.resolve(id) == :ok

      assert [
               {"thread_started", id, project.id},
               {"resolved", id, project.id},
               {"resolved", id, project.id}
             ] == items(["thread_started", "resolved"])
    end

    test "a refused start or Resolve, and a schedule's start, collect nothing", %{
      project: project
    } do
      ambient!(true)
      assert Threads.start(project.id, " ") == {:error, :blank}
      assert Threads.start("p_missing", "hello") == {:error, :not_found}
      assert Threads.resolve("c_missing") == {:error, :not_found}

      source = %{"kind" => "routine", "schedule_id" => "sc_backups"}

      {:ok, thread} =
        Durable.commit(&Threads.start_tx(&1, project.id, "[Scheduled] Backups", source: source))

      idle!(thread.id)
      assert items(["thread_started", "resolved"]) == []
    end

    test "with ambient mode off, nothing is collected", %{project: project} do
      ambient!(false)
      id = idle_thread!(project, "hello")
      assert Threads.resolve(id) == :ok
      assert Repo.all(DigestItem) == []
    end
  end

  describe "review marks" do
    test "mark_reviewed_tx/3 and unmark_reviewed_tx/2 set and clear the column, and announce once per project",
         %{project: project} do
      {:ok, other} = Projects.create(%{"purpose" => "Paint the house.", "name" => "House"})
      one = idle_thread!(project, "hello")
      two = idle_thread!(project, "files")
      three = idle_thread!(other, "hello")
      untouched = idle_thread!(project, "hello again")
      # The Store announces a commit before the next one runs, so after
      # this one the runs' own announcements are out of the way.
      :ok = Durable.commit(fn _tx -> :ok end)
      :ok = Projects.subscribe()
      now = DateTime.utc_now()

      assert Durable.commit(&Threads.mark_reviewed_tx(&1, [one, two, three], now)) == :ok
      assert_receive {:projects_changed, project_id}
      assert_receive {:projects_changed, other_id}
      refute_receive {:projects_changed, _}, 50
      assert Enum.sort([project_id, other_id]) == Enum.sort([project.id, other.id])

      assert Enum.map([one, two, three], &Threads.get(&1).reviewed_at) == [now, now, now]
      assert Threads.get(untouched).reviewed_at == nil
      assert Threads.state(one).thread.reviewed_at == now

      assert Durable.commit(&Threads.unmark_reviewed_tx(&1, [one, two])) == :ok
      assert_receive {:projects_changed, project_id}
      refute_receive {:projects_changed, _}, 50
      assert project_id == project.id
      assert Enum.map([one, two, three], &Threads.get(&1).reviewed_at) == [nil, nil, now]

      assert Durable.commit(&Threads.unmark_reviewed_tx(&1, [])) == :ok
      refute_receive {:projects_changed, _}, 50
    end
  end
end
