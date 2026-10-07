defmodule Photon.QuestionsTest do
  @moduledoc """
  `ask_blip` questions through `Photon.Questions` (section 4 of
  `docs/plans/step-4-blip-as-coordinator.md`), on the durable harness.
  The step table itself is covered in `test/core/questions/rules_test.exs`;
  here, that the API applies it to the row and does what goes with each
  step: the signal to Blip, the answer's wake-up signal and its message
  in Blip's conversation, the notices, and the announcements.

  A question belongs to a tool call. Until `ask_blip` arrives, a test
  stands one in with a waiting task in the thread's conversation that
  nothing wakes. Most tests stop the Scheduler first (`still!/0`), so
  nothing runs under them: Blip's runs and the thread's stay where the
  commits left them.
  """

  use Photon.DataCase, async: false

  @moduletag :durable

  alias Photon.{Assistant, Projects, Questions, Threads}
  alias Photon.Durable.{Entry, Scheduler, Signal, Submission, TaskRecord, Tx}
  alias Photon.Questions.Question

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
               "question_id" => asked.id
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
      {asked, _task} = ask!(thread, project, "Which deploy branch?")

      # Blip's scripted run answers the message in prose and settles it.
      assert %{status: "done"} = await_settled(blip, asked.submission_id)

      assert {:ok, passed} = Questions.escalate(asked.id)
      assert {passed.status, passed.passed_by, passed.wording} == {"with_owner", "hub", nil}
      assert_receive {:questions_changed, _}

      assert [%{"message" => message, "question_id" => question_id}] = notices(blip)
      assert message == ~s{I didn't get to "files"'s question, so it's with you now.}
      assert question_id == asked.id

      # Once: a second check finds it with the owner.
      assert {:ok, %{status: "with_owner"}} = Questions.escalate(asked.id)
      assert length(notices(blip)) == 1

      assert {:ok, answered} = Questions.answer(asked.id, "main")
      assert Questions.Rules.result(answered) == "The user answered: main"
      idle!(blip)
    end
  end
end
