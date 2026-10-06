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

  alias Photon.{Assistant, Projects, Settings, Threads}
  alias Photon.Durable.{Conversation, Submission}
  alias Photon.Threads.Thread

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
      assert shed_row == %{id: shed_thread, title: "sort the tools", running?: false}
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
    test "has the machine tools and the four context-file tools, nothing else", %{
      project: project
    } do
      thread = start!(project, "hello")
      conversation = Durable.conversation(thread.id)

      assert conversation |> Threads.tools() |> Enum.map(& &1.name()) |> Enum.sort() ==
               Enum.sort(~w(shell view_image list_machines list_context_files read_context_file
                   write_context_file edit_context_file))
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

      for text <- ["Henry", "Europe/London", "French", "mp1", "Blip"],
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
end
