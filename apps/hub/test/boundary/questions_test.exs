defmodule Photon.QuestionsTest do
  @moduledoc """
  `ask_blip` questions through `Photon.Questions` (section 4 of
  `docs/plans/step-4-blip-as-coordinator.md`), on the durable harness.
  The step table itself is covered in `test/core/questions/rules_test.exs`;
  here, that the API applies it to the row and does what goes with each
  step: the signal to Blip, the answer's wake-up signal and its message
  in Blip's conversation, the notices, and the announcements.

  A question belongs to a tool call. The API's tests stand one in with a
  waiting task in the thread's conversation that nothing wakes, and most
  stop the Scheduler first (`still!/0`), so nothing runs under them:
  Blip's runs and the thread's stay where the commits left them.

  The `ask_blip` tests run the scripted thread's `ask blip:` with Blip
  parked on a command that never finishes (on `box`, a machine the test
  process plays), so the message carrying the question stays queued and
  the call never escalates; Blip's side is driven with
  `Photon.Questions.answer_tx/4` and `pass_tx/4`.

  The Blip-driven tests let the scripted Blip handle the question
  (section 8.2): it answers from its memory with `answer_question`, asks
  the owner with `ask_owner`, or replies in prose to a question ending in
  `(prose)`, which the hub then passes on itself.
  """

  use Photon.DataCase, async: false

  @moduletag :durable

  import Ecto.Query, only: [from: 2]
  import Photon.Fixtures, only: [call: 3]

  alias Photon.{Assistant, Projects, Questions, Signals, Threads}
  alias Photon.Durable.{Entry, Scheduler, Signal, Store, Submission, TaskRecord, ToolAPI, Tx}
  alias Photon.Questions.Question
  alias Photon.Threads.Tools.AskBlip
  alias PhotonCore.Message

  setup do
    {:ok, project} =
      Projects.create(%{"purpose" => "Keep the garden watered.", "name" => "Garden"})

    :ok = Questions.subscribe()
    %{project: project, blip: Assistant.conversation_id()}
  end

  defp still!, do: :ok = stop_supervised!(Scheduler)

  defp thread!(project, text \\ "files") do
    {:ok, thread} = Threads.start(project.id, text)
    thread
  end

  # A tool call that waits and that nothing wakes, standing in for an
  # `ask_blip` call in the thread.
  defp call!(thread) do
    Durable.create_task(%{
      kind: "test_ask",
      conversation_id: thread.id,
      waiting: %{"signal" => "never"}
    })
  end

  defp new(thread, project, task, question) do
    %{
      task_id: task.id,
      thread_id: thread.id,
      thread_title: thread.title,
      project_id: project.id,
      project_slug: project.slug,
      project_name: project.name,
      question: question
    }
  end

  defp ask!(thread, project, question) do
    task = call!(thread)
    assert {:ok, %Question{} = asked} = Questions.ask(new(thread, project, task, question))
    assert_receive {:questions_changed, thread_id}
    assert thread_id == thread.id
    {asked, task}
  end

  defp answer_tx(id, text, by), do: Durable.commit(&Questions.answer_tx(&1, id, text, by))
  defp pass_tx(id, wording, by), do: Durable.commit(&Questions.pass_tx(&1, id, wording, by))
  defp withdraw_tx(task_id), do: Durable.commit(&Questions.withdraw_tx(&1, task_id))

  defp notices(blip) do
    for %Entry{kind: "error", data: %{"notice" => true} = data} <- Durable.entries(blip),
        do: data
  end

  defp parts(%Submission{content: %{"parts" => parts}}), do: Enum.map(parts, & &1["text"])
  defp refs(%Submission{content: %{"source" => %{"signals" => refs}}}), do: refs

  defp idle!(conversation_id) do
    :ok = Durable.subscribe(conversation_id)

    if Durable.busy?(conversation_id),
      do: await_change(conversation_id, fn _changes -> not Durable.busy?(conversation_id) end)

    :ok
  end

  ## The ask_blip tool

  defp fake_machine(name) do
    {:ok, _owner} =
      Registry.register(Photon.MachineRegistry, name, %{
        "platform" => "test",
        "workspace" => "/w",
        "version" => "0",
        "capabilities" => ["ops:2"]
      })
  end

  # Parks Blip on a command that never finishes, so a question's message
  # queues behind its run and stays there.
  defp park_blip!(blip) do
    fake_machine("box")
    {:ok, _parked} = Assistant.send("on box: $ sleep 1000")
    assert Durable.busy?(blip)
    :ok
  end

  # Starts a thread whose first message asks Blip `question`; returns the
  # thread and its question once it is asked.
  defp asking!(project, question) do
    {:ok, thread} = Threads.start(project.id, "ask blip: " <> question)
    :ok = Durable.subscribe(thread.id)
    thread_id = thread.id
    assert_receive {:questions_changed, ^thread_id}, 5_000
    assert %{^thread_id => [asked]} = Questions.open_by_thread([thread_id])
    {thread, asked}
  end

  # The call's task once it is parked and `fun` holds for what it waits on.
  defp parked!(thread, task_id, fun) do
    task = Durable.task(task_id)

    if task.status == "waiting" and fun.(task.waiting) do
      task
    else
      changes =
        await_change(thread.id, fn changes ->
          Enum.any?(changes.tasks, &(&1.id == task_id and parked?(&1, fun)))
        end)

      Enum.find(changes.tasks, &(&1.id == task_id))
    end
  end

  defp parked?(task, fun), do: task.status == "waiting" and fun.(task.waiting)

  # Waits for two more of the call's checks, each parking it with a later one.
  defp checked_twice!(thread, task_id) do
    first = parked!(thread, task_id, &is_integer(&1["until"]))
    second = parked!(thread, task_id, &(&1["until"] > first.waiting["until"]))
    _third = parked!(thread, task_id, &(&1["until"] > second.waiting["until"]))
    :ok
  end

  # The ask_blip call's result: status, text and details.
  defp result!(thread) do
    entry =
      await_entry(thread.id, &(&1.kind == "tool_result" and &1.data["name"] == "ask_blip"))

    {entry.data["status"], Message.text_of(entry.data["message"]), entry.data["details"]}
  end

  defp restart_durable! do
    :ok = stop_supervised!(Scheduler)
    :ok = stop_supervised!(Store)
    _store = start_supervised!(Store)
    _scheduler = start_supervised!(Scheduler)
    :ok
  end

  describe "the ask_blip tool" do
    test "waits while Blip has the question, and Blip's answer ends the call", %{
      project: project,
      blip: blip
    } do
      park_blip!(blip)
      {thread, asked} = asking!(project, "which deploy branch?")

      assert {asked.question, asked.thread_title, asked.project_slug} ==
               {"which deploy branch?", thread.title, "garden"}

      assert Repo.get!(Submission, asked.submission_id).status == "queued"
      assert %{state: :asking, asking_blip?: true} = Threads.state(thread.id)

      # The call checks on it, and while the message waits in Blip's queue
      # it leaves the question with Blip.
      checked_twice!(thread, asked.task_id)
      assert %Question{status: "asked", passed_by: nil} = Questions.get(asked.id)
      assert notices(blip) == []

      assert {:ok, _answered} = answer_tx(asked.id, "staging", {:blip, false})

      assert result!(thread) ==
               {"ok", "Blip answered: staging",
                %{"question_id" => asked.id, "answered_by" => "blip"}}

      idle!(thread.id)
      assert List.last(texts(thread.id, "assistant")) == "Blip answered: staging"
      assert %{state: :unread, questions: []} = Threads.state(thread.id)
    end

    test "once the owner has it, the call waits for their answer alone, and gets it", %{
      project: project,
      blip: blip
    } do
      park_blip!(blip)
      {first, first_q} = asking!(project, "which deploy branch?")
      {second, second_q} = asking!(project, "is the gate locked?")

      {:ok, _passed} = pass_tx(first_q.id, "Which branch should deploys go to?", :blip)
      {:ok, _passed} = pass_tx(second_q.id, nil, :hub)

      # No more checks: only an answer or a Stop moves the call now.
      for {thread, question} <- [{first, first_q}, {second, second_q}] do
        key = Questions.signal_key(question.id)
        _task = parked!(thread, question.task_id, &(&1 == %{"signal" => key}))
        assert %{state: :waiting, asking_blip?: false} = Threads.state(thread.id)
      end

      # Answered in the other order: each call gets its own answer.
      assert {:ok, _answered} = Questions.answer(second_q.id, "yes")

      assert result!(second) ==
               {"ok", "The user answered: yes",
                %{"question_id" => second_q.id, "answered_by" => "owner"}}

      assert {:ok, _answered} = Questions.answer(first_q.id, "main")

      assert result!(first) ==
               {"ok",
                "Blip asked the user: Which branch should deploys go to?\nThey answered: main",
                %{"question_id" => first_q.id, "answered_by" => "owner"}}

      idle!(first.id)
      idle!(second.id)
    end

    test "Stop while Blip has the question withdraws it and takes back its message", %{
      project: project,
      blip: blip
    } do
      park_blip!(blip)
      {thread, asked} = asking!(project, "which deploy branch?")
      _task = parked!(thread, asked.task_id, &is_integer(&1["until"]))

      :ok = Threads.stop(thread.id)

      assert result!(thread) == {"aborted", "Stopped by the user before it finished.", %{}}
      assert %Question{status: "withdrawn"} = Questions.get(asked.id)
      assert Repo.get!(Submission, asked.submission_id).status == "withdrawn"
      assert notices(blip) == []

      assert Questions.answer(asked.id, "main") ==
               {:error, ~s{"#{thread.title}" was stopped, so its question was withdrawn.}}

      assert answer_tx(asked.id, "staging", {:blip, false}) == {:error, :withdrawn}
    end

    test "Stop while the owner has the question withdraws it with a notice", %{
      project: project,
      blip: blip
    } do
      park_blip!(blip)
      {thread, asked} = asking!(project, "which deploy branch?")
      {:ok, _passed} = pass_tx(asked.id, "Which branch?", :blip)
      key = Questions.signal_key(asked.id)
      _task = parked!(thread, asked.task_id, &(&1 == %{"signal" => key}))

      :ok = Threads.stop(thread.id)

      assert result!(thread) == {"aborted", "Stopped by the user before it finished.", %{}}
      assert %Question{status: "withdrawn", answer: nil} = Questions.get(asked.id)

      assert [%{"message" => message, "question_id" => question_id}] = notices(blip)
      assert message == ~s{"#{thread.title}" was stopped, so its question was withdrawn.}
      assert question_id == asked.id

      assert Questions.answer(asked.id, "main") == {:error, message}
      refute Repo.get(Signal, key)
    end

    @tag :capture_log
    test "a raise in the tool withdraws the question in the commit that records the error", %{
      project: project,
      blip: blip
    } do
      park_blip!(blip)
      {thread, asked} = asking!(project, "which deploy branch?")
      _task = parked!(thread, asked.task_id, &is_integer(&1["until"]))

      # The parked call's state is lost, so its next check raises.
      :ok = stop_supervised!(Scheduler)

      {1, _} =
        Repo.update_all(from(t in TaskRecord, where: t.id == ^asked.task_id),
          set: [checkpoint: %{"state" => %{}}, waiting: %{"until" => 0}]
        )

      _scheduler = start_supervised!(Scheduler)

      assert {"error", "Error: " <> _message, %{}} = result!(thread)
      assert %Question{status: "withdrawn"} = Questions.get(asked.id)
      assert Repo.get!(Submission, asked.submission_id).status == "withdrawn"
      idle!(thread.id)
    end

    test "a hub restart while the call waits on the owner loses nothing", %{
      project: project,
      blip: blip
    } do
      park_blip!(blip)
      {thread, asked} = asking!(project, "which deploy branch?")
      {:ok, _passed} = pass_tx(asked.id, "Which branch?", :blip)
      key = Questions.signal_key(asked.id)
      _task = parked!(thread, asked.task_id, &(&1 == %{"signal" => key}))

      :ok = restart_durable!()
      assert %TaskRecord{status: "waiting"} = Durable.task(asked.task_id)

      assert {:ok, _answered} = Questions.answer(asked.id, "main")

      assert {"ok", "Blip asked the user: Which branch?\nThey answered: main", _details} =
               result!(thread)

      idle!(thread.id)
    end

    test "an answer recorded while the Scheduler is down wakes the call when it starts", %{
      project: project,
      blip: blip
    } do
      park_blip!(blip)
      {thread, asked} = asking!(project, "which deploy branch?")
      {:ok, _passed} = pass_tx(asked.id, nil, :hub)
      key = Questions.signal_key(asked.id)
      _task = parked!(thread, asked.task_id, &(&1 == %{"signal" => key}))

      :ok = stop_supervised!(Scheduler)
      assert {:ok, _answered} = Questions.answer(asked.id, "main")
      assert %TaskRecord{status: "waiting"} = Durable.task(asked.task_id)
      _scheduler = start_supervised!(Scheduler)

      assert {"ok", "The user answered: main", _details} = result!(thread)
      idle!(thread.id)
    end
  end

  describe "Blip handles the question" do
    # Starts a thread whose first message asks Blip `question`, with Blip
    # free to run on it.
    defp ask_blip!(project, question) do
      {:ok, thread} = Threads.start(project.id, "ask blip: " <> question)
      :ok = Durable.subscribe(thread.id)
      thread
    end

    # The thread's question once it has `status`, waiting for the change.
    defp question!(thread, status) do
      thread_id = thread.id

      case Repo.one(from(q in Question, where: q.thread_id == ^thread_id)) do
        %Question{status: ^status} = question ->
          question

        _other ->
          assert_receive {:questions_changed, ^thread_id}, 5_000
          question!(thread, status)
      end
    end

    # Blip's newest result for a call of `name`: status, text and details.
    defp blip_result!(blip, name) do
      entry =
        await_entry(blip, fn entry ->
          entry.kind == "tool_result" and entry.data["name"] == name
        end)

      {entry.data["status"], Message.text_of(entry.data["message"]), entry.data["details"]}
    end

    defp blip_results(blip, name) do
      for %Entry{kind: "tool_result", data: %{"name" => ^name} = data} <- Durable.entries(blip),
          do: {data["status"], Message.text_of(data["message"])}
    end

    test "answers from memory: the thread gets Blip's answer and its run finishes", %{
      project: project,
      blip: blip
    } do
      :ok = Assistant.put_memory("- the NAS is mp1\n- deploy branch: staging")
      :ok = Durable.subscribe(blip)
      thread = ask_blip!(project, "which deploy branch should I use?")

      assert {"ok", "Blip answered: staging", %{"question_id" => id, "answered_by" => "blip"}} =
               result!(thread)

      assert %Question{status: "answered", answered_by: "blip", answer: "staging"} =
               Questions.get(id)

      assert {"ok", text, details} = blip_result!(blip, "answer_question")
      assert text == ~s{Sent your answer to "#{Questions.get(id).thread_title}".}
      assert %{"question_id" => ^id, "answered_by" => "blip"} = details
      assert details["thread_id"] == thread.id

      idle!(thread.id)
      assert List.last(texts(thread.id, "assistant")) == "Blip answered: staging"
      assert %{state: :unread, questions: []} = Threads.state(thread.id)
      idle!(blip)
      assert blip_results(blip, "ask_owner") == []
    end

    test "asks the owner when its memory doesn't settle it, and passes their answer on", %{
      project: project,
      blip: blip
    } do
      :ok = Durable.subscribe(blip)
      thread = ask_blip!(project, "what colour should the gate be?")
      passed = question!(thread, "with_owner")

      wording = ~s{"#{passed.thread_title}" asks: what colour should the gate be?}
      assert {passed.passed_by, passed.wording} == {"blip", wording}

      assert {"ok", text, details} = blip_result!(blip, "ask_owner")

      assert text ==
               ~s{Asked the user. Their answer goes straight to "#{passed.thread_title}"; you'll see it here.}

      assert details == %{
               "question_id" => passed.id,
               "thread_id" => thread.id,
               "title" => passed.thread_title,
               "project_id" => project.id,
               "slug" => "garden",
               "project" => "Garden",
               "wording" => wording
             }

      assert %{state: :waiting, asking_blip?: false} = Threads.state(thread.id)
      idle!(blip)

      # The owner answers from Blip's panel.
      assert {:ok, %Question{answered_by: "owner"}} = Assistant.answer(passed.id, "green")

      assert result!(thread) ==
               {"ok", "Blip asked the user: #{wording}\nThey answered: green",
                %{"question_id" => passed.id, "answered_by" => "owner"}}

      # Blip gets the answer as a message of its own, and notes it.
      answer = await_entry(blip, &(&1.kind == "user" and &1.data["source"]["kind"] == "answer"))
      assert answer.data["source"]["question_id"] == passed.id
      idle!(blip)
      assert List.last(texts(blip, "assistant")) == "Noted."
      idle!(thread.id)
    end

    test "two questions passed to the owner in one message, answered in the other order", %{
      project: project,
      blip: blip
    } do
      # Both arrive while Blip is busy, so they share one message, and
      # Blip's run on it asks the owner about each.
      park_blip!(blip)
      {first, first_q} = asking!(project, "which deploy branch?")
      {second, second_q} = asking!(project, "is the gate locked?")
      assert first_q.submission_id == second_q.submission_id

      :ok = Assistant.stop()
      first_q = question!(first, "with_owner")
      second_q = question!(second, "with_owner")
      assert first_q.passed_by == "blip" and second_q.passed_by == "blip"
      idle!(blip)
      assert length(blip_results(blip, "ask_owner")) == 2

      assert {:ok, _answered} = Questions.answer(second_q.id, "yes")

      assert {"ok", text, _details} = result!(second)
      assert text == "Blip asked the user: #{second_q.wording}\nThey answered: yes"

      assert {:ok, _answered} = Questions.answer(first_q.id, "main")

      assert {"ok", text, _details} = result!(first)
      assert text == "Blip asked the user: #{first_q.wording}\nThey answered: main"

      idle!(first.id)
      idle!(second.id)
      idle!(blip)
    end

    test "Blip's answer to a question with the owner counts only when the owner wrote to it", %{
      project: project,
      blip: blip
    } do
      :ok = Durable.subscribe(blip)
      thread = ask_blip!(project, "what colour should the gate be?")
      passed = question!(thread, "with_owner")
      idle!(blip)

      # A run another thread's question started tries to answer it.
      ref = %{
        "kind" => "question",
        "key" => "test:other",
        "question_id" => "q_other",
        "thread_id" => "c_other"
      }

      signal =
        Durable.commit(
          &Signals.post_tx(&1, %{key: "test:other", text: "answer #{passed.id}: red", ref: ref})
        )

      await_settled(blip, signal.id)

      assert List.last(blip_results(blip, "answer_question")) ==
               {"error",
                "Error: #{passed.id} is with the user. Wait for their answer; it goes to the thread without you."}

      assert %Question{status: "with_owner", answer: nil} = Questions.get(passed.id)

      # The owner writes to Blip: their answer goes through, as theirs.
      {:ok, typed} = Assistant.send("answer: green")
      await_settled(blip, typed.id)

      assert {"ok", ~s{Sent your answer to "#{passed.thread_title}".}} ==
               List.last(blip_results(blip, "answer_question"))

      assert %Question{status: "answered", answered_by: "owner", answer: "green"} =
               Questions.get(passed.id)

      assert {"ok", text, _details} = result!(thread)
      assert text == "Blip asked the user: #{passed.wording}\nThey answered: green"

      idle!(thread.id)
    end

    test "an unknown question's ID gets the open ones listed", %{project: project, blip: blip} do
      :ok = Durable.subscribe(blip)
      thread = ask_blip!(project, "what colour should the gate be?")
      passed = question!(thread, "with_owner")
      idle!(blip)

      {:ok, typed} = Assistant.send("answer q_missing: green")
      await_settled(blip, typed.id)

      assert List.last(blip_results(blip, "answer_question")) ==
               {"error",
                ~s{Error: There's no open question q_missing. Open: #{passed.id} from "#{passed.thread_title}" (with the user).}}

      assert %Question{status: "with_owner"} = Questions.get(passed.id)
      :ok = Threads.stop(thread.id)
      idle!(thread.id)
    end

    test "a question Blip replies to in prose is passed to the owner by the hub", %{
      project: project,
      blip: blip
    } do
      :ok = Durable.subscribe(blip)
      thread = ask_blip!(project, "is the gate locked? (prose)")

      passed = question!(thread, "with_owner")
      assert {passed.passed_by, passed.wording} == {"hub", nil}
      assert blip_results(blip, "ask_owner") == []
      assert blip_results(blip, "answer_question") == []

      assert [%{"message" => message, "question_id" => question_id}] = notices(blip)

      assert message ==
               ~s{I didn't get to "#{passed.thread_title}"'s question, so it's with you now.}

      assert question_id == passed.id
      assert %{state: :waiting} = Threads.state(thread.id)

      assert {:ok, _answered} = Questions.answer(passed.id, "yes, since Monday")

      assert {"ok", "The user answered: yes, since Monday",
              %{"question_id" => passed.id, "answered_by" => "owner"}} == result!(thread)

      idle!(thread.id)
      idle!(blip)
    end
  end

  describe "AskBlip, called directly" do
    setup %{project: project} do
      still!()
      %{thread: thread!(project)}
    end

    # A tool call in the thread for `args`, waiting, as the harness runs it.
    defp api(thread, args) do
      task =
        Durable.create_task(%{
          kind: "tool",
          conversation_id: thread.id,
          phase: "run",
          input: %{"call" => call("ask_blip", args, "call_1")},
          waiting: %{"signal" => "never"}
        })

      ToolAPI.new(task)
    end

    defp blip_messages(blip),
      do: Repo.aggregate(from(s in Submission, where: s.conversation_id == ^blip), :count)

    test "a rerun of execute finds the question: no second one, no second signal", %{
      thread: thread,
      blip: blip
    } do
      args = %{"question" => "  Which deploy branch? "}
      api = api(thread, args)

      assert {:wait, %{"signal" => "question:" <> id, "until" => until}, %{"question_id" => id}} =
               AskBlip.execute(args, api)

      assert is_integer(until)
      assert %Question{question: "Which deploy branch?", task_id: task_id} = Questions.get(id)
      assert task_id == api.task.id

      assert {:wait, %{"signal" => "question:" <> ^id}, %{"question_id" => ^id}} =
               AskBlip.execute(args, api)

      assert Repo.aggregate(Question, :count) == 1
      assert blip_messages(blip) == 1
    end

    test "resume follows the question: waits on, escalates, or returns the answer", %{
      thread: thread,
      blip: blip
    } do
      api = api(thread, %{"question" => "Which deploy branch?"})
      {:wait, _waiting, state} = AskBlip.execute(%{"question" => "Which deploy branch?"}, api)
      %{"question_id" => id} = state
      key = Questions.signal_key(id)

      # Blip's run has the message: check again later.
      assert {:wait, %{"signal" => ^key, "until" => _until}, ^state} = AskBlip.resume(state, api)
      assert %Question{status: "asked"} = Questions.get(id)

      # Blip's run went past it: the hub passes it on, and the call waits
      # on the answer alone.
      {1, _} =
        Repo.update_all(
          from(s in Submission, where: s.id == ^Questions.get(id).submission_id),
          set: [status: "done"]
        )

      assert AskBlip.resume(state, api) == {:wait, %{"signal" => key}, state}
      assert %Question{status: "with_owner", passed_by: "hub"} = Questions.get(id)
      assert [%{"question_id" => ^id}] = notices(blip)

      {:ok, _answered} = Questions.answer(id, "staging")

      assert AskBlip.resume(state, api) ==
               {:ok, "The user answered: staging",
                %{"question_id" => id, "answered_by" => "owner"}}

      assert AskBlip.resume(%{"question_id" => "q_missing"}, api) ==
               {:error, "The hub has no record of this question."}
    end

    test "on_interrupt withdraws the call's question, and resume then says so", %{
      thread: thread
    } do
      args = %{"question" => "Which deploy branch?"}
      api = api(thread, args)
      {:wait, _waiting, state} = AskBlip.execute(args, api)

      assert Durable.commit(&AskBlip.on_interrupt(api, &1)) == :ok
      assert %Question{status: "withdrawn"} = Questions.get(state["question_id"])
      assert AskBlip.resume(state, api) == {:error, "This question was withdrawn."}
    end

    test "a bad question, or a call already being stopped, asks nothing", %{
      thread: thread,
      blip: blip
    } do
      api = api(thread, %{"question" => " "})
      assert AskBlip.execute(%{"question" => " "}, api) == {:error, "Ask one specific question."}

      long = String.duplicate("a", 2_001)

      assert {:error, "Keep the question under 2,000 characters" <> _} =
               AskBlip.execute(%{"question" => long}, api)

      args = %{"question" => "Which deploy branch?"}
      stopping = api(thread, args)
      _task = Durable.abort_task(stopping.task.id)

      assert AskBlip.execute(args, stopping) ==
               {:error, "The call was stopped before Blip got the question."}

      assert Repo.aggregate(Question, :count) == 0
      assert blip_messages(blip) == 0
    end
  end

  describe "ask/1" do
    test "stores the question, posts it to Blip, and a rerun finds it", %{
      project: project,
      blip: blip
    } do
      still!()
      thread = thread!(project)
      {asked, task} = ask!(thread, project, "Which deploy branch?")

      assert %Question{
               status: "asked",
               question: "Which deploy branch?",
               thread_title: "files",
               project_slug: "garden",
               project_name: "Garden",
               submission_id: carrier_id
             } = asked

      assert "q_" <> _ = asked.id
      carrier = Repo.get!(Submission, carrier_id)
      assert carrier.conversation_id == blip
      assert carrier.request_id == "signal:question:" <> asked.id

      assert parts(carrier) == [
               ~s{[Question #{asked.id} from Garden / "files" (#{thread.id})]\nWhich deploy branch?}
             ]

      assert [%{"kind" => "question", "question_id" => question_id, "key" => key}] =
               refs(carrier)

      assert {question_id, key} == {asked.id, "question:" <> asked.id}

      # A rerun of the call's step finds the question and posts nothing new.
      assert {:ok, again} = Questions.ask(new(thread, project, task, "Which deploy branch?"))
      assert again.id == asked.id
      assert Repo.aggregate(Question, :count) == 1
      assert Repo.aggregate(Submission, :count, :id) == 2

      assert Questions.by_task(task.id).id == asked.id
      assert [%{id: ^question_id}] = Questions.open()
    end

    test "the thread asking Blip, then waiting on the owner, on the board", %{project: project} do
      still!()
      thread = thread!(project)
      {asked, _task} = ask!(thread, project, "Which deploy branch?")

      assert %{state: :asking, asking_blip?: true, questions: [%{id: id}]} =
               Threads.state(thread.id)

      assert id == asked.id
      assert [%{state: :asking}] = Threads.board({:project, project.id})
      assert [%{threads: [%{state: :asking}]}] = Threads.sidebar(5)

      assert {:ok, _passed} = pass_tx(asked.id, "Which branch should deploys go to?", :blip)
      assert %{state: :waiting, asking_blip?: false} = Threads.state(thread.id)
      assert Threads.needs_you_count() == 1

      assert {:ok, _answered} = Questions.answer(asked.id, "main")
      assert %{state: :running, questions: []} = Threads.state(thread.id)
    end

    test "makes nothing for a call that is being stopped or has ended", %{
      project: project,
      blip: blip
    } do
      still!()
      thread = thread!(project)

      # Marked for abort; nothing has stopped it yet.
      marked = call!(thread)
      _task = Durable.abort_task(marked.id)
      assert %TaskRecord{abort_requested: true, status: "waiting"} = Durable.task(marked.id)
      assert Questions.ask(new(thread, project, marked, "Which branch?")) == {:error, :stopped}

      ended = call!(thread)

      %TaskRecord{status: "done"} =
        Durable.commit(&Tx.finish(&1, Tx.get_task(&1, ended.id), "done", %{}))

      assert Questions.ask(new(thread, project, ended, "Which branch?")) == {:error, :stopped}

      assert Repo.aggregate(Question, :count) == 0
      assert Durable.queued(blip) == []
      assert Durable.entries(blip) == []
      refute_received {:questions_changed, _}
    end
  end

  describe "answering and passing on" do
    setup %{project: project} do
      still!()
      %{thread: thread!(project)}
    end

    test "Blip answers a question it has, and the call's signal is recorded", %{
      project: project,
      thread: thread
    } do
      {asked, _task} = ask!(thread, project, "Which deploy branch?")
      refute Repo.get(Signal, Questions.signal_key(asked.id))

      assert {:ok, answered} = answer_tx(asked.id, "staging", {:blip, false})

      assert {answered.status, answered.answered_by, answered.answer} ==
               {"answered", "blip", "staging"}

      assert answered.answered_at
      assert Repo.get(Signal, Questions.signal_key(asked.id))
      assert_receive {:questions_changed, _}

      assert Questions.Rules.result(Questions.get(asked.id)) == "Blip answered: staging"
      assert answer_tx(asked.id, "main", {:blip, true}) == {:error, :answered}
      assert Questions.open() == []
    end

    test "the owner can't answer a question Blip still has", %{project: project, thread: thread} do
      {asked, _task} = ask!(thread, project, "Which deploy branch?")

      assert Questions.answer(asked.id, "main") ==
               {:error, ~s{Blip has "files"'s question; it'll ask you if it needs to.}}

      assert %Question{status: "asked", answer: nil} = Questions.get(asked.id)
      refute Repo.get(Signal, Questions.signal_key(asked.id))
      refute_received {:questions_changed, _}
    end

    test "Blip passes a question on once, with its wording", %{project: project, thread: thread} do
      {asked, _task} = ask!(thread, project, "Which deploy branch?")

      assert {:ok, passed} = pass_tx(asked.id, "Which branch should deploys go to?", :blip)

      assert {passed.status, passed.passed_by, passed.wording} ==
               {"with_owner", "blip", "Which branch should deploys go to?"}

      assert passed.passed_at
      assert_receive {:questions_changed, _}

      assert pass_tx(asked.id, "Again?", :blip) == {:error, :already_passed}
      assert pass_tx(asked.id, nil, :hub) == {:error, :already_passed}
      assert {:ok, %{status: "with_owner", passed_by: "blip"}} = Questions.escalate(asked.id)
    end

    test "Blip's answer to a question with the owner counts only when the owner wrote to it", %{
      project: project,
      thread: thread
    } do
      {asked, _task} = ask!(thread, project, "Which deploy branch?")
      {:ok, _passed} = pass_tx(asked.id, "Which branch?", :blip)

      assert answer_tx(asked.id, "staging", {:blip, false}) == {:error, :with_owner}
      assert %Question{status: "with_owner", answer: nil} = Questions.get(asked.id)

      assert {:ok, answered} = answer_tx(asked.id, "main", {:blip, true})
      assert {answered.status, answered.answered_by} == {"answered", "owner"}

      assert Questions.Rules.result(answered) ==
               "Blip asked the user: Which branch?\nThey answered: main"
    end

    test "the owner's answer goes to the thread and into Blip's conversation", %{
      project: project,
      thread: thread,
      blip: blip
    } do
      {asked, _task} = ask!(thread, project, "Which deploy branch?")
      {:ok, _passed} = pass_tx(asked.id, "Which branch?", :blip)
      assert_receive {:questions_changed, _}

      assert {:ok, answered} = Questions.answer(asked.id, "  main  ")

      assert {answered.status, answered.answered_by, answered.answer} ==
               {"answered", "owner", "main"}

      assert Repo.get(Signal, Questions.signal_key(asked.id))
      assert_receive {:questions_changed, thread_id}
      assert thread_id == thread.id

      # Blip's run on the question is still waiting to start, so the answer
      # queues behind it.
      assert [message] =
               Enum.filter(Durable.queued(blip), &(&1.request_id == "answer:" <> asked.id))

      assert parts(message) == [
               ~s{[Your answer to #{asked.id} from Garden / "files" (#{thread.id}) went straight to the thread.]},
               "main"
             ]

      assert message.content["source"] == %{
               "kind" => "answer",
               "question_id" => asked.id,
               "thread_id" => thread.id,
               "title" => "files",
               "slug" => "garden",
               "project" => "Garden"
             }

      assert Submission.background?(message)

      # Answered once: a second answer is refused and sends nothing.
      assert Questions.answer(asked.id, "staging") ==
               {:error, ~s{"files"'s question was already answered.}}

      assert length(
               Enum.filter(Durable.queued(blip), &(&1.content["source"]["kind"] == "answer"))
             ) ==
               1
    end

    test "an empty answer, or an unknown question, is refused", %{
      project: project,
      thread: thread
    } do
      {asked, _task} = ask!(thread, project, "Which deploy branch?")
      {:ok, _passed} = pass_tx(asked.id, "Which branch?", :blip)

      assert Questions.answer(asked.id, "  ") == {:error, "Write an answer."}

      assert Questions.answer("q_missing", "main") ==
               {:error, "That question isn't there any more."}

      assert answer_tx("q_missing", "main", {:blip, true}) == {:error, :not_found}
      assert pass_tx("q_missing", "Which?", :blip) == {:error, :not_found}
      assert Questions.escalate("q_missing") == {:error, :not_found}
      assert %Question{status: "with_owner"} = Questions.get(asked.id)
    end
  end

  describe "withdraw_tx/2" do
    setup %{project: project} do
      still!()
      %{thread: thread!(project)}
    end

    test "takes back questions Blip hasn't seen, from a merged message too", %{
      project: project,
      thread: thread,
      blip: blip
    } do
      # The first question starts Blip's run; the next two wait in one
      # message behind it.
      {first, _} = ask!(thread, project, "One?")
      {second, second_task} = ask!(thread, project, "Two?")
      {third, third_task} = ask!(thread, project, "Three?")
      assert Repo.get!(Submission, first.submission_id).status == "placed"
      assert second.submission_id == third.submission_id

      assert withdraw_tx(second_task.id) == :ok
      assert %Question{status: "withdrawn"} = Questions.get(second.id)
      assert_receive {:questions_changed, _}
      carrier = Repo.get!(Submission, third.submission_id)
      assert {carrier.status, length(parts(carrier))} == {"queued", 1}
      assert [%{"question_id" => third_id}] = refs(carrier)
      assert third_id == third.id

      assert withdraw_tx(third_task.id) == :ok
      assert Repo.get!(Submission, third.submission_id).status == "withdrawn"

      # Blip had them, so the owner hears nothing.
      assert notices(blip) == []
      assert %{questions: [%{id: first_id}]} = Threads.state(thread.id)
      assert first_id == first.id
    end

    test "a question with the owner is withdrawn with a notice, and can't be answered", %{
      project: project,
      thread: thread,
      blip: blip
    } do
      {asked, task} = ask!(thread, project, "Which deploy branch?")
      {:ok, _passed} = pass_tx(asked.id, "Which branch?", :blip)

      assert withdraw_tx(task.id) == :ok
      assert %Question{status: "withdrawn", answer: nil} = Questions.get(asked.id)

      assert [notice] = notices(blip)

      assert notice == %{
               "message" => ~s{"files" was stopped, so its question was withdrawn.},
               "notice" => true,
               "question_id" => asked.id,
               "question_notice" => "withdrawn",
               "thread_id" => thread.id,
               "title" => "files",
               "slug" => "garden",
               "project" => "Garden"
             }

      assert Questions.answer(asked.id, "main") ==
               {:error, ~s{"files" was stopped, so its question was withdrawn.}}

      assert answer_tx(asked.id, "main", {:blip, true}) == {:error, :withdrawn}
      refute Repo.get(Signal, Questions.signal_key(asked.id))

      # Once is enough.
      assert withdraw_tx(task.id) == :ok
      assert length(notices(blip)) == 1
    end

    test "an answered question stays answered, and a call without one is fine", %{
      project: project,
      thread: thread
    } do
      {asked, task} = ask!(thread, project, "Which deploy branch?")
      {:ok, _answered} = answer_tx(asked.id, "staging", {:blip, false})

      assert withdraw_tx(task.id) == :ok
      assert %Question{status: "answered", answer: "staging"} = Questions.get(asked.id)

      assert withdraw_tx(call!(thread).id) == :ok
      assert withdraw_tx("t_missing") == :ok
      assert withdraw_tx(nil) == :ok
    end
  end

  describe "escalate/1" do
    test "does nothing while Blip's run hasn't been through the question", %{project: project} do
      still!()
      thread = thread!(project)
      {asked, _task} = ask!(thread, project, "Which deploy branch?")
      assert Repo.get!(Submission, asked.submission_id).status == "placed"

      assert {:ok, %Question{status: "asked", passed_by: nil}} = Questions.escalate(asked.id)
      refute_received {:questions_changed, _}
    end

    test "passes a question Blip's run went past to the owner, with a notice", %{
      project: project,
      blip: blip
    } do
      thread = thread!(project)
      idle!(thread.id)
      :ok = Durable.subscribe(blip)
      {asked, _task} = ask!(thread, project, "Is the gate locked? (prose)")

      # Blip's scripted run answers the message in prose and settles it.
      assert %{status: "done"} = await_settled(blip, asked.submission_id)

      assert {:ok, passed} = Questions.escalate(asked.id)
      assert {passed.status, passed.passed_by, passed.wording} == {"with_owner", "hub", nil}
      assert_receive {:questions_changed, _}

      assert [%{"message" => message, "question_id" => question_id} = notice] = notices(blip)
      assert message == ~s{I didn't get to "files"'s question, so it's with you now.}
      assert question_id == asked.id

      # The panel draws it as the question's card, in the thread's own words.
      assert %{
               "question_notice" => "escalated",
               "question" => "Is the gate locked? (prose)",
               "title" => "files",
               "slug" => "garden"
             } = notice

      # Once: a second check finds it with the owner.
      assert {:ok, %{status: "with_owner"}} = Questions.escalate(asked.id)
      assert length(notices(blip)) == 1

      assert {:ok, answered} = Questions.answer(asked.id, "main")
      assert Questions.Rules.result(answered) == "The user answered: main"
      idle!(blip)
    end
  end
end
