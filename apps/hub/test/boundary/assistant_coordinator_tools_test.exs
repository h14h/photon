defmodule Photon.AssistantCoordinatorToolsTest do
  @moduledoc """
  Blip's tools over projects and threads (section 5 of
  `docs/plans/step-4-blip-as-coordinator.md`), driven through the scripted
  Blip on the durable harness: what each returns, and what it changed.
  The texts themselves are covered in `test/core/assistant/readout_test.exs`;
  here, that the tools read the right rows and name what they read.
  """

  use Photon.DataCase, async: false

  @moduletag :durable

  import Ecto.Query, only: [from: 2]

  alias Photon.{Assistant, Projects, Questions, Schedules, Signals, Skills, Threads}
  alias Photon.Assistant.Tools
  alias Photon.Durable.{Submission, TaskRecord, ToolAPI}
  alias Photon.Projects.ContextFile
  alias PhotonCore.Message

  setup do
    {:ok, garden} =
      Projects.create(%{
        "purpose" => "Keep the vegetable beds watered. And the pump running.",
        "name" => "Garden"
      })

    {:ok, house} =
      Projects.create(%{"purpose" => "Fix things around the house.", "name" => "House"})

    blip = Assistant.conversation_id()
    :ok = Durable.subscribe(blip)
    %{garden: garden, house: house, blip: blip}
  end

  defp idle!(conversation_id) do
    :ok = Durable.subscribe(conversation_id)

    if Durable.busy?(conversation_id),
      do: await_change(conversation_id, fn _changes -> not Durable.busy?(conversation_id) end)

    :ok
  end

  # Starts a thread with the owner's message and waits until its run has
  # ended and Blip has heard about it, if it was going to.
  defp ended!(project, text) do
    {:ok, thread} = Threads.start(project.id, text)
    :ok = idle!(thread.id)
    :ok = idle!(Assistant.conversation_id())
    thread
  end

  # Sends Blip `text` once it is idle and returns the result of the tool
  # call its answer made: the text and the result's data.
  defp tool!(blip, text, name) do
    :ok = idle!(blip)
    {:ok, s} = Assistant.send(text)
    await_settled(blip, s.id)
    last_result!(blip, name)
  end

  defp last_result!(blip, name) do
    entry =
      blip
      |> Durable.entries()
      |> Enum.filter(&(&1.kind == "tool_result"))
      |> List.last()

    assert entry.data["name"] == name
    {Message.text_of(entry.data["message"]), entry.data}
  end

  # Posts a signal into Blip's conversation whose text is one of the
  # scripted Blip's phrasings, so the run it starts calls a tool as a run
  # started by a thread update, a thread's question, a digest or a daily
  # review would. The scripted Blip reads the message's text and nothing
  # else, and who asked comes from the ref's kind alone
  # (`Photon.Assistant.Origin`).
  defp post!(kind, text, thread_id) do
    key = "test:#{System.unique_integer([:positive])}"

    ref =
      case kind do
        :update ->
          %{"kind" => "thread_update", "status" => "finished", "thread_id" => thread_id}

        :question ->
          %{"kind" => "question", "question_id" => "q_" <> key, "thread_id" => thread_id}

        :digest ->
          %{"kind" => "digest", "items" => [], "more" => 0, "more_smaller" => 0}

        :review ->
          %{"kind" => "review", "items" => [], "more" => 0}
      end

    ref = Map.put(ref, "key", key)
    Durable.commit(&Signals.post_tx(&1, %{key: key, text: text, ref: ref}))
  end

  # Posts such a signal once Blip is idle, and returns the result of the
  # tool call its run made.
  defp signal_tool!(blip, kind, text, name, thread_id \\ "c_asking") do
    :ok = idle!(blip)
    signal = post!(kind, text, thread_id)
    await_settled(blip, signal.id)
    last_result!(blip, name)
  end

  defp fake_machine(name) do
    {:ok, _owner} =
      Registry.register(Photon.MachineRegistry, name, %{
        "platform" => "test",
        "workspace" => "/w",
        "version" => "0",
        "capabilities" => ["ops:2"]
      })
  end

  # A thread the owner started, parked on a command that never finishes on
  # `box`, a machine the test process plays.
  defp parked_thread!(project) do
    fake_machine("box")
    {:ok, thread} = Threads.start(project.id, "on box: $ sleep 1000")
    :ok = Threads.subscribe(thread.id)
    await_entry(thread.id, &(&1.kind == "assistant"))
    assert Durable.busy?(thread.id)
    thread
  end

  # Blip's finished tool task for its newest call of `name`.
  defp tool_task!(blip, name) do
    query = from(t in TaskRecord, where: t.conversation_id == ^blip and t.kind == "tool")

    query
    |> Repo.all()
    |> Enum.filter(&(&1.input["call"]["name"] == name))
    |> Enum.max_by(& &1.inserted_at, DateTime)
  end

  defp submissions(thread_id),
    do:
      Repo.all(
        from(s in Submission,
          where: s.conversation_id == ^thread_id,
          order_by: [asc: s.inserted_at, asc: s.id]
        )
      )

  describe "list_projects" do
    test "every project with its threads' states and its files", %{garden: garden, blip: blip} do
      _failed = ended!(garden, "fail: the pump is unplugged")
      _asked = ended!(garden, "ask me: which seeds should I order")
      {:ok, _file} = Projects.create_file(garden.id, %{"name" => "notes.md", "content" => "Hi."})

      {text, data} = tool!(blip, "projects", "list_projects")
      assert data["status"] == "ok"

      assert text ==
               "garden: Garden. Keep the vegetable beds watered. 1 waiting on the user, " <>
                 "1 failed. 1 context file.\n" <>
                 "house: House. Fix things around the house. No threads. No context files."
    end
  end

  describe "read_project" do
    test "by slug or ID: purpose, files, threads, schedules and skills", %{
      garden: garden,
      blip: blip
    } do
      failed = ended!(garden, "fail: the pump is unplugged")
      {:ok, _file} = Projects.create_file(garden.id, %{"name" => "notes.md", "content" => "Hi."})

      {:ok, skill} =
        Skills.create(%{
          "name" => "pdf-forms",
          "description" => "Fill in PDF forms.",
          "instructions" => "# PDF forms\n\nFill each field."
        })

      :ok = Skills.enable(skill.id, {:project, garden.id})

      params =
        Map.merge(Schedules.new_params(DateTime.utc_now()), %{
          "prompt" => "check the beds",
          "target" => failed.id
        })

      {:ok, schedule} = Schedules.create({:project, garden.id}, params)

      {text, data} = tool!(blip, "project garden", "read_project")
      assert data["details"] == %{"project_id" => garden.id, "slug" => "garden"}

      assert text =~
               "Garden (garden, ID #{garden.id})\n" <>
                 "Purpose: Keep the vegetable beds watered. And the pump running.\n\n"

      assert text =~ ~r/Context files:\n- notes\.md \(3 characters, changed .* by the user\)/

      assert text =~
               ~s(Threads \(1, most recent first\):\n- #{failed.id} "#{failed.title}": failed)

      assert text =~ ~s(- #{schedule.id}: )
      assert text =~ ~s(wakes #{failed.id} "#{failed.title}": "check the beds")
      assert text =~ "Skills on: pdf-forms."

      {by_id, _data} = tool!(blip, "project #{garden.id}", "read_project")
      assert by_id == text
    end

    test "a project with no skills of its own names the machines' skills its threads get",
         %{blip: blip} do
      {:ok, _key} = Photon.NodeKeys.issue("mm1")

      {:ok, skill} =
        Skills.create(%{
          "name" => "ios-simulators",
          "description" => "Run iOS simulators.",
          "instructions" => "Boot one."
        })

      :ok = Skills.enable(skill.id, {:machine, "mm1"})

      {text, _data} = tool!(blip, "project garden", "read_project")

      assert String.ends_with?(
               text,
               "Skills on: none.\n" <>
                 "Also offered to its threads, for work on that machine: mm1 has ios-simulators."
             )
    end

    test "an unknown project lists the slugs there are", %{blip: blip} do
      {text, data} = tool!(blip, "project gardn", "read_project")
      assert data["status"] == "error"
      assert text == "Error: There's no project called gardn. Projects: garden, house."
    end
  end

  describe "list_threads" do
    test "every thread, or a project's, with open questions", %{
      garden: garden,
      house: house,
      blip: blip
    } do
      failed = ended!(garden, "fail: the pump is unplugged")

      # The asking thread's run waits for the answer, so it stays busy.
      :ok = Questions.subscribe()
      {:ok, asking} = Threads.start(house.id, "ask blip: what colour should the gate be?")
      asking_id = asking.id
      assert_receive {:questions_changed, ^asking_id}, 5_000
      assert %{^asking_id => [question]} = Questions.open_by_thread([asking_id])

      {text, _data} = tool!(blip, "threads", "list_threads")
      lines = String.split(text, "\n")
      assert length(lines) == 2

      first = hd(lines)
      assert String.starts_with?(first, ~s(#{asking_id} "#{asking.title}" \(house\): ))
      assert first =~ "question #{question.id}, "
      assert first =~ ": what colour should the gate be?"

      assert List.last(lines) ==
               ~s(#{failed.id} "#{failed.title}" \(garden\): failed: ) <>
                 "HTTP 500: the pump is unplugged"

      {text, data} = tool!(blip, "threads in garden", "list_threads")
      assert text == List.last(lines)
      assert data["details"] == %{"project_id" => garden.id, "slug" => "garden"}
    end

    test "an empty list says so, and an unknown project is an error", %{blip: blip} do
      {text, _data} = tool!(blip, "threads", "list_threads")
      assert text == "No threads."

      {text, _data} = tool!(blip, "threads in house", "list_threads")
      assert text == "No threads in house."

      {text, data} = tool!(blip, "threads in shed", "list_threads")
      assert data["status"] == "error"
      assert text == "Error: There's no project called shed. Projects: garden, house."
    end
  end

  describe "read_thread" do
    test "the header and the latest items, without marking the thread seen", %{
      garden: garden,
      blip: blip
    } do
      thread = ended!(garden, "files")
      before = Threads.get(thread.id)
      assert before.last_run_status == "done"

      {text, data} = tool!(blip, "read thread #{thread.id}", "read_thread")

      assert data["details"] == %{
               "thread_id" => thread.id,
               "project_id" => garden.id,
               "title" => thread.title
             }

      assert text =~ ~s("#{thread.title}" \(#{thread.id}\), in Garden \(garden\)\n)
      assert text =~ "State: finished, not yet seen by the user\n"
      assert text =~ "Started by the user; last activity "

      assert String.ends_with?(
               text,
               "\n\n[user] files\n[thread] Checking the context files.\n" <>
                 "[tool] Listed the context files\n[thread] This project has no context files yet."
             )

      assert Threads.get(thread.id).seen_at == before.seen_at
      assert Threads.state(thread.id).state == :unread
    end

    test "an unknown thread points to list_threads", %{blip: blip} do
      {text, data} = tool!(blip, "read thread c_999", "read_thread")
      assert data["status"] == "error"
      assert text == "Error: There's no thread c_999. list_threads shows them."
    end
  end

  describe "start_project" do
    test "makes a project from a purpose", %{blip: blip} do
      {text, data} = tool!(blip, "start project: Keep the bees healthy.", "start_project")
      project = Projects.get(data["details"]["project_id"])
      assert project.purpose == "Keep the bees healthy."
      assert text == "Started #{project.slug} (#{project.name})."
      assert data["details"]["slug"] == project.slug
    end

    test "a refused purpose comes back as the rules say, and makes nothing", %{blip: blip} do
      before = length(Projects.list())
      long = String.duplicate("bees ", 900)
      {text, data} = tool!(blip, "start project: " <> long, "start_project")
      assert data["status"] == "error"

      assert text ==
               "Error: purpose: Keep the purpose under 4,000 characters, " <>
                 "and put the rest in a context file."

      assert length(Projects.list()) == before
    end
  end

  describe "start_thread" do
    test "starts a thread as Blip's, once however often the call runs", %{
      garden: garden,
      blip: blip
    } do
      {text, data} = tool!(blip, "start thread in garden: files", "start_thread")
      assert data["status"] == "ok"
      assert [thread] = Threads.list(garden.id)
      assert thread.started_by == "blip"

      assert text ==
               ~s(Started "#{thread.title}" in garden \(#{thread.id}\). ) <>
                 "You'll get an update when its run ends."

      assert data["details"] == %{
               "thread_id" => thread.id,
               "title" => thread.title,
               "project_id" => garden.id,
               "slug" => "garden"
             }

      assert [%{content: %{"source" => %{"kind" => "blip"}}}] = submissions(thread.id)

      # The call run again (as after a restart) finds the thread it made.
      task = tool_task!(blip, "start_thread")
      args = %{"project" => "garden", "message" => "files"}
      {:commit, fun} = Tools.StartThread.execute(args, ToolAPI.new(task))
      assert {:ok, _text, %{"thread_id" => thread_id}} = Durable.commit(fun)
      assert thread_id == thread.id
      assert [_one] = Threads.list(garden.id)
      assert [_one] = submissions(thread.id)
    end

    test "an unknown project lists the slugs there are", %{blip: blip} do
      {text, data} = tool!(blip, "start thread in shed: files", "start_thread")
      assert data["status"] == "error"
      assert text == "Error: There's no project called shed. Projects: garden, house."
    end
  end

  describe "message_thread" do
    test "sends Blip's message to an idle thread, and queues or steers into a busy one", %{
      garden: garden,
      house: house,
      blip: blip
    } do
      idle = ended!(garden, "files")
      {text, data} = tool!(blip, "tell #{idle.id}: files", "message_thread")
      assert text == ~s(Sent to "#{idle.title}"; it's working on it.)

      assert data["details"] == %{
               "thread_id" => idle.id,
               "title" => idle.title,
               "project_id" => garden.id
             }

      assert [_first, %{content: %{"source" => %{"kind" => "blip"}}}] = submissions(idle.id)

      busy = parked_thread!(house)
      {text, _data} = tool!(blip, "tell #{busy.id}: files", "message_thread")
      assert text == ~s(Queued for "#{busy.title}", behind its current run.)
      assert [_running, %{status: "queued", mode: "follow_up"}] = submissions(busy.id)

      # A steer, from a second call in the same owner's run.
      task = tool_task!(blip, "message_thread")
      args = %{"thread" => busy.id, "message" => "now", "when_busy" => "steer"}
      {:commit, fun} = Tools.MessageThread.execute(args, ToolAPI.new(%{task | id: "t_steer"}))
      assert {:ok, text, _details} = Durable.commit(fun)
      assert text == ~s("#{busy.title}" will see it after its current step.)
      assert [_running, _queued, %{status: "queued", mode: "steer"}] = submissions(busy.id)

      # Any other when_busy is a follow-up: "reject" would roll back the call's commit.
      for {when_busy, n} <- [{"reject", "t_reject"}, {"now", "t_now"}] do
        args = %{"thread" => busy.id, "message" => when_busy, "when_busy" => when_busy}
        {:commit, fun} = Tools.MessageThread.execute(args, ToolAPI.new(%{task | id: n}))
        assert {:ok, text, _details} = Durable.commit(fun)
        assert text == ~s(Queued for "#{busy.title}", behind its current run.)
      end

      assert [_running, _queued, _steer, %{mode: "follow_up"}, %{mode: "follow_up"}] =
               submissions(busy.id)

      :ok = Threads.stop(busy.id)
      :ok = idle!(busy.id)
    end

    test "an unknown thread points to list_threads", %{blip: blip} do
      {text, data} = tool!(blip, "tell c_999: files", "message_thread")
      assert data["status"] == "error"
      assert text == "Error: There's no thread c_999. list_threads shows them."
    end
  end

  describe "stop_thread" do
    test "stops a running thread, and says when there was nothing to stop", %{
      garden: garden,
      blip: blip
    } do
      busy = parked_thread!(garden)
      {text, data} = tool!(blip, "stop thread #{busy.id}", "stop_thread")
      assert text == ~s(Stopped "#{busy.title}".)
      assert data["details"]["thread_id"] == busy.id
      :ok = idle!(busy.id)
      assert Threads.get(busy.id).last_run_status == "stopped"

      {text, data} = tool!(blip, "stop thread #{busy.id}", "stop_thread")
      assert data["status"] == "ok"
      assert text == ~s("#{busy.title}" wasn't running; nothing to stop.)
    end
  end

  describe "context files" do
    test "list_context_files and read_context_file name writers from Blip's side", %{
      garden: garden,
      blip: blip
    } do
      {text, data} = tool!(blip, "files in garden", "list_context_files")
      assert {data["status"], text} == {"ok", "This project has no context files yet."}
      assert data["details"] == %{"project_id" => garden.id, "slug" => "garden"}

      writer = ended!(garden, "write zones.md: three zones")
      {:ok, _file} = Projects.create_file(garden.id, %{"name" => "plan.md", "content" => ""})
      {_text, _data} = tool!(blip, "write garden/notes.md: hello", "write_context_file")

      {text, _data} = tool!(blip, "files in #{garden.id}", "list_context_files")
      lines = String.split(text, "\n")
      assert length(lines) == 3
      assert Enum.any?(lines, &(&1 =~ ~r/\A- notes\.md \(5 characters, changed .* by you\)\z/))

      assert Enum.any?(
               lines,
               &(&1 =~ ~r/\A- plan\.md \(0 characters, changed .* by the user\)\z/)
             )

      assert Enum.any?(
               lines,
               &(&1 =~
                   ~r/\A- zones\.md \(11 characters, changed .* by thread "#{writer.title}"\)\z/)
             )

      {text, data} = tool!(blip, "read garden/Zones", "read_context_file")
      assert data["status"] == "ok"
      assert data["details"] == %{"project_id" => garden.id, "slug" => "garden"}

      assert text =~
               ~r/\Azones\.md, 11 characters, changed .* by thread "#{writer.title}":\nthree zones\z/
    end

    test "a missing file or project is an error that says what there is", %{
      garden: garden,
      blip: blip
    } do
      {:ok, _file} = Projects.create_file(garden.id, %{"name" => "notes.md", "content" => "hi"})

      {text, data} = tool!(blip, "read garden/todo.md", "read_context_file")
      assert data["status"] == "error"
      assert text == "Error: There's no todo.md. This project's context files are: notes.md."

      {text, _data} = tool!(blip, "read house/todo.md", "read_context_file")
      assert text == "Error: There's no todo.md. This project has no context files yet."

      for {phrase, name} <- [
            {"files in gardn", "list_context_files"},
            {"read gardn/notes.md", "read_context_file"},
            {"write gardn/notes.md: hi", "write_context_file"},
            {"edit gardn/notes.md: hi => bye", "edit_context_file"}
          ] do
        {text, data} = tool!(blip, phrase, name)
        assert data["status"] == "error", name
        assert text == "Error: There's no project called gardn. Projects: garden, house.", name
      end
    end

    test "write_context_file creates or replaces a file as Blip's, and announces it", %{
      garden: garden,
      blip: blip
    } do
      :ok = Projects.subscribe_files(garden.id)
      garden_id = garden.id

      {text, data} = tool!(blip, "write garden/notes.md: hello", "write_context_file")
      assert {data["status"], text} == {"ok", "Created notes.md in garden (5 characters)."}

      assert data["details"] == %{
               "project_id" => garden.id,
               "slug" => "garden",
               "file" => "notes.md",
               "version" => 1
             }

      assert_receive {:project_files_changed, ^garden_id, "notes.md"}

      assert %ContextFile{content: "hello", version: 1, updated_by: "blip"} =
               Projects.get_file(garden.id, "notes.md")

      {text, _data} = tool!(blip, "write garden/Notes.md: hello, world", "write_context_file")
      assert text == "Wrote notes.md in garden (12 characters)."
      assert %ContextFile{version: 2} = Projects.get_file(garden.id, "notes.md")

      {text, data} = tool!(blip, "write garden/x*y.md: hi", "write_context_file")
      assert data["status"] == "error"
      assert text =~ "Error: A file name uses letters"
    end

    test "edit_context_file changes one passage as Blip's; a bad edit changes nothing", %{
      garden: garden,
      blip: blip
    } do
      {:ok, _file} =
        Projects.create_file(garden.id, %{"name" => "notes.md", "content" => "zone 2 stuck"})

      {text, data} = tool!(blip, "edit garden/notes.md: stuck => fixed", "edit_context_file")
      assert {data["status"], text} == {"ok", "Edited notes.md in garden."}

      assert data["details"] == %{
               "project_id" => garden.id,
               "slug" => "garden",
               "file" => "notes.md",
               "version" => 2
             }

      assert %ContextFile{content: "zone 2 fixed", updated_by: "blip"} =
               Projects.get_file(garden.id, "notes.md")

      {text, _data} = tool!(blip, "edit garden/notes.md: stuck => fixed", "edit_context_file")
      assert text == "Error: old_text wasn't found in notes.md."
      assert %ContextFile{version: 2} = Projects.get_file(garden.id, "notes.md")
    end

    test "a project gone between the lookup and the commit says so", %{blip: blip} do
      {:ok, shed} = Projects.create(%{"purpose" => "Tidy the shed.", "name" => "Shed"})
      {_text, _data} = tool!(blip, "files in shed", "list_context_files")
      api = ToolAPI.new(tool_task!(blip, "list_context_files"))

      {:commit, write} =
        Tools.WriteContextFile.execute(
          %{"project" => "shed", "name" => "notes.md", "content" => "hi"},
          api
        )

      {:commit, edit} =
        Tools.EditContextFile.execute(
          %{"project" => "shed", "name" => "notes.md", "old_text" => "a", "new_text" => "b"},
          api
        )

      _deleted = Repo.delete!(shed)
      assert Durable.commit(write) == {:error, "That project no longer exists."}
      assert Durable.commit(edit) == {:error, "That project no longer exists."}
    end
  end

  describe "a thread's question" do
    @refused "Error: A thread's question can't start or change work. " <>
               "Answer it with answer_question, or ask the user with ask_owner."

    test "keeps a run from starting or changing work, while reading works", %{
      garden: garden,
      blip: blip
    } do
      busy = parked_thread!(garden)
      idle = ended!(garden, "files")
      projects = length(Projects.list())
      {:ok, _plan} = Projects.create_file(garden.id, %{"name" => "plan.md", "content" => "beds"})

      {:ok, schedule} =
        Schedules.create(
          {:project, garden.id},
          Map.put(Schedules.new_params(DateTime.utc_now()), "prompt", "check the beds")
        )

      {:ok, _skill} =
        Skills.create(%{
          "name" => "pdf-forms",
          "description" => "Fill in PDF forms.",
          "instructions" => "# PDF forms"
        })

      for {text, name} <- [
            {"start project: Keep the bees healthy.", "start_project"},
            {"start thread in garden: files", "start_thread"},
            {"tell #{idle.id}: files", "message_thread"},
            {"stop thread #{busy.id}", "stop_thread"},
            {"write garden/notes.md: hello", "write_context_file"},
            {"edit garden/plan.md: beds => pots", "edit_context_file"},
            {"in 5 minutes in garden: files", "schedule"},
            {"in 5 minutes: files", "schedule"},
            {"cancel schedule #{schedule.id}", "cancel_schedule"},
            {"turn on pdf-forms in garden", "set_project_skill"}
          ] do
        {result, data} = signal_tool!(blip, :question, text, name)
        assert {data["status"], result} == {"error", @refused}, name
      end

      assert [%{id: schedule_id}] = Schedules.list({:project, garden.id})
      assert schedule_id == schedule.id
      assert Schedules.list(:blip) == []
      assert Skills.enabled({:project, garden.id}) == []

      assert length(Projects.list()) == projects

      assert [%ContextFile{name: "plan.md", content: "beds", version: 1}] =
               Projects.list_files(garden.id)

      assert [_busy, _idle] = Threads.list(garden.id)
      assert [_first] = submissions(idle.id)
      assert Durable.busy?(busy.id)

      for {text, name} <- [
            {"project garden", "read_project"},
            {"files in garden", "list_context_files"},
            {"read garden/plan.md", "read_context_file"},
            {"schedules in garden", "list_schedules"},
            {"all skills", "list_skills"}
          ] do
        {_text, data} = signal_tool!(blip, :question, text, name)
        assert data["status"] == "ok", name
      end

      :ok = Threads.stop(busy.id)
      :ok = idle!(busy.id)
    end

    test "the owner's steer in the same run lifts the limits", %{garden: garden, blip: blip} do
      fake_machine("box")
      :ok = idle!(blip)
      _question = post!(:question, "on box: $ sleep 1000", "c_asking")
      await_entry(blip, &(&1.kind == "assistant"))

      {:ok, steer} = Assistant.send("start thread in garden: files", when_busy: "steer")

      # The steer is placed after the tool round, which ends when its call is stopped.
      shell = tool_task!(blip, "shell")
      _aborted = Durable.abort_task(shell.id)
      await_settled(blip, steer.id)

      {_text, data} = last_result!(blip, "start_thread")
      assert data["status"] == "ok"
      assert [%{started_by: "blip"}] = Threads.list(garden.id)
    end

    test "a question that arrives next to an update gets a run of its own, still limited", %{
      garden: garden,
      blip: blip
    } do
      fake_machine("box")
      :ok = idle!(blip)
      {:ok, parked} = Assistant.send("on box: $ sleep 1000")
      await_entry(blip, &(&1.kind == "assistant"))

      update = post!(:update, "projects", "c_done")
      question = post!(:question, "start thread in garden: files", "c_asking")
      assert update.id != question.id

      :ok = Assistant.stop()
      await_settled(blip, parked.id)
      await_settled(blip, update.id)
      await_settled(blip, question.id)

      {text, _data} = last_result!(blip, "start_thread")
      assert text == @refused
      assert Threads.list(garden.id) == []
    end
  end

  describe "a digest or a daily review" do
    @report_only "Error: A digest or review run only reports. " <>
                   "Tell the user what you'd do, and do it when they say so."

    test "only reports: what starts or changes work refuses, while reading and memory work", %{
      garden: garden,
      blip: blip
    } do
      busy = parked_thread!(garden)
      idle = ended!(garden, "files")
      projects = length(Projects.list())
      {:ok, _plan} = Projects.create_file(garden.id, %{"name" => "plan.md", "content" => "beds"})

      {:ok, schedule} =
        Schedules.create(
          {:project, garden.id},
          Map.put(Schedules.new_params(DateTime.utc_now()), "prompt", "check the beds")
        )

      {:ok, _skill} =
        Skills.create(%{
          "name" => "pdf-forms",
          "description" => "Fill in PDF forms.",
          "instructions" => "# PDF forms"
        })

      refusals = [
        {"start project: Keep the bees healthy.", "start_project"},
        {"start thread in garden: files", "start_thread"},
        {"tell #{idle.id}: files", "message_thread"},
        {"stop thread #{busy.id}", "stop_thread"},
        {"write garden/notes.md: hello", "write_context_file"},
        {"edit garden/plan.md: beds => pots", "edit_context_file"},
        {"in 5 minutes in garden: files", "schedule"},
        {"in 5 minutes: files", "schedule"},
        {"cancel schedule #{schedule.id}", "cancel_schedule"},
        {"turn on pdf-forms in garden", "set_project_skill"}
      ]

      for kind <- [:digest, :review], {text, name} <- refusals do
        {result, data} = signal_tool!(blip, kind, text, name)
        assert {data["status"], result} == {"error", @report_only}, "#{kind}: #{name}"
      end

      assert [%{id: schedule_id}] = Schedules.list({:project, garden.id})
      assert schedule_id == schedule.id
      assert Schedules.list(:blip) == []
      assert Skills.enabled({:project, garden.id}) == []
      assert length(Projects.list()) == projects

      assert [%ContextFile{name: "plan.md", content: "beds", version: 1}] =
               Projects.list_files(garden.id)

      assert [_busy, _idle] = Threads.list(garden.id)
      assert [_first] = submissions(idle.id)
      assert Durable.busy?(busy.id)

      for kind <- [:digest, :review],
          {text, name} <- [
            {"read thread #{idle.id}", "read_thread"},
            {"project garden", "read_project"},
            {"read garden/plan.md", "read_context_file"},
            {"schedules in garden", "list_schedules"},
            {"remember the pump is in the shed", "update_memory"}
          ] do
        {_text, data} = signal_tool!(blip, kind, text, name)
        assert data["status"] == "ok", "#{kind}: #{name}"
      end

      assert Assistant.memory() =~ "the pump is in the shed"

      :ok = Threads.stop(busy.id)
      :ok = idle!(busy.id)
    end

    test "the owner's steer in the same run lifts it", %{garden: garden, blip: blip} do
      idle = ended!(garden, "files")
      fake_machine("box")
      :ok = idle!(blip)
      _digest = post!(:digest, "on box: $ sleep 1000", nil)
      await_entry(blip, &(&1.kind == "assistant"))

      {:ok, steer} = Assistant.send("tell #{idle.id}: files", when_busy: "steer")

      # The steer is placed after the tool round, which ends when its call is stopped.
      shell = tool_task!(blip, "shell")
      _aborted = Durable.abort_task(shell.id)
      await_settled(blip, steer.id)

      {_text, data} = last_result!(blip, "message_thread")
      assert data["status"] == "ok"
      assert [_first, _blips] = submissions(idle.id)
      :ok = idle!(idle.id)
    end
  end

  describe "the unattended limit" do
    setup do
      previous = Application.get_env(:photon, Photon.Assistant, [])
      Application.put_env(:photon, Photon.Assistant, unattended_limit: 2)
      on_exit(fn -> Application.put_env(:photon, Photon.Assistant, previous) end)
    end

    # Blip messages `thread` from a run a thread update started, and the
    # thread's run (and the update it posts back to Blip) end.
    defp follow_up!(blip, thread) do
      result =
        signal_tool!(blip, :update, "tell #{thread.id}: files", "message_thread", thread.id)

      :ok = idle!(thread.id)
      :ok = idle!(blip)
      result
    end

    test "stops Blip messaging threads on its own until the owner writes", %{
      garden: garden,
      blip: blip
    } do
      thread = ended!(garden, "files")

      # What Blip does in a run the owner typed into doesn't count.
      {_text, data} = tool!(blip, "tell #{thread.id}: files", "message_thread")
      assert data["status"] == "ok"
      refute Map.has_key?(data["details"], "unattended")
      :ok = idle!(thread.id)
      :ok = idle!(blip)

      assert {_text, %{"status" => "ok", "details" => %{"unattended" => true}}} =
               follow_up!(blip, thread)

      assert {_text, %{"status" => "ok"}} = follow_up!(blip, thread)
      assert length(submissions(thread.id)) == 4

      {text, data} = follow_up!(blip, thread)
      assert data["status"] == "error"

      assert text ==
               "Error: You've started or messaged threads 2 times since the user last wrote " <>
                 "to you. Tell them what's going on and wait for them."

      assert length(submissions(thread.id)) == 4

      # The owner's own runs are never refused, and their message starts
      # the count again.
      {_text, data} = tool!(blip, "tell #{thread.id}: files", "message_thread")
      assert data["status"] == "ok"
      :ok = idle!(thread.id)
      :ok = idle!(blip)

      assert {_text, %{"status" => "ok"}} = follow_up!(blip, thread)
      assert length(submissions(thread.id)) == 6
    end

    test "an owner's run past the limit leaves Blip's follow-ups their own count", %{
      garden: garden,
      blip: blip
    } do
      thread = ended!(garden, "files")

      for _round <- 1..3 do
        {_text, data} = tool!(blip, "tell #{thread.id}: files", "message_thread")
        assert data["status"] == "ok"
        :ok = idle!(thread.id)
        :ok = idle!(blip)
      end

      assert {_text, %{"status" => "ok"}} = follow_up!(blip, thread)
    end
  end

  describe "a project's schedule" do
    test "is refused in a run the owner didn't type into", %{garden: garden, blip: blip} do
      {text, data} =
        signal_tool!(blip, :update, "every 5 minutes in garden: files", "schedule", "c_done")

      assert data["status"] == "error"

      assert text ==
               "Error: Only the user can set up work in a project on a schedule. Ask them, " <>
                 "or leave out project for a reminder to yourself."

      assert Schedules.list({:project, garden.id}) == []

      # A reminder to itself is still fine.
      {_text, data} = signal_tool!(blip, :update, "in 5 minutes: files", "schedule", "c_done")
      assert data["status"] == "ok"
      assert [%{schedule: %{asked_by: "blip"}}] = Schedules.list(:blip)
    end

    test "is made in a run the owner typed into, as the owner's", %{garden: garden, blip: blip} do
      {_text, data} = tool!(blip, "every 5 minutes in garden: files", "schedule")
      assert data["status"] == "ok"

      assert [%{schedule: %{created_by: "blip", asked_by: "owner"}}] =
               Schedules.list({:project, garden.id})
    end
  end
end
