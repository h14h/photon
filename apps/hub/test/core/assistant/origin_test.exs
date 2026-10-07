defmodule Photon.Assistant.OriginTest do
  @moduledoc """
  Who asked for one of Blip's runs, and what it may do (section 5.4 of
  `docs/plans/step-4-blip-as-coordinator.md`).
  """

  use Photon.Case, async: true

  alias Photon.Assistant.Origin

  @user %{"kind" => "user"}
  @answer %{"kind" => "answer", "question_id" => "q_1", "thread_id" => "c_1"}

  defp routine(asked_by),
    do: %{
      "kind" => "routine",
      "schedule_id" => "sc_1",
      "created_by" => "blip",
      "asked_by" => asked_by
    }

  defp update(thread_id),
    do: %{"kind" => "thread_update", "key" => "settle:s_#{thread_id}", "thread_id" => thread_id}

  defp question(question_id, thread_id),
    do: %{
      "kind" => "question",
      "key" => "question:#{question_id}",
      "question_id" => question_id,
      "thread_id" => thread_id
    }

  defp carrying(refs), do: %{"kind" => "signal", "signals" => refs}

  defp by(sources), do: sources |> Origin.of() |> Map.take([:by, :id])

  describe "of/1: who asked" do
    test "each row of the table" do
      assert by([@user]) == %{by: "owner", id: nil}
      assert by([@answer]) == %{by: "owner", id: nil}
      assert by([routine("blip")]) == %{by: "follow_up", id: "sc_1"}
      assert by([routine("owner")]) == %{by: "schedule", id: "sc_1"}
      assert by([carrying([question("q_1", "c_1")])]) == %{by: "thread", id: "c_1"}
      assert by([carrying([update("c_1")])]) == %{by: "follow_up", id: "c_1"}
      assert by([]) == %{by: "unknown", id: nil}
      assert by([%{"kind" => "something new"}]) == %{by: "unknown", id: nil}
    end

    test "the owner wins over anything else in the run" do
      assert by([carrying([question("q_1", "c_1")]), @user]) == %{by: "owner", id: nil}
      assert by([carrying([update("c_1")]), @answer]) == %{by: "owner", id: nil}
      assert by([routine("blip"), @user]) == %{by: "owner", id: nil}
    end

    test "a routine is a schedule unless Blip asked for it, one-off or repeating" do
      assert by([routine("owner")]).by == "schedule"
      assert by([Map.delete(routine("owner"), "asked_by")]).by == "schedule"
      assert by([routine("blip")]).by == "follow_up"
    end

    test "updates name their thread only when there is one" do
      assert by([carrying([update("c_1"), update("c_1")])]) == %{by: "follow_up", id: "c_1"}
      assert by([carrying([update("c_1"), update("c_2")])]) == %{by: "follow_up", id: nil}
    end

    test "questions name their thread only when every one is from it" do
      one = carrying([question("q_1", "c_1"), question("q_2", "c_1")])
      two = carrying([question("q_1", "c_1"), question("q_2", "c_2")])
      assert by([one]) == %{by: "thread", id: "c_1"}
      assert by([two]) == %{by: "thread", id: nil}

      assert Origin.of([two]).questions == [
               %{question_id: "q_1", thread_id: "c_1"},
               %{question_id: "q_2", thread_id: "c_2"}
             ]
    end
  end

  describe "of/1: what the run may do" do
    test "questions alone restrict the run" do
      origin = Origin.of([carrying([question("q_1", "c_1")])])
      assert origin.restricted?
      refute origin.owner_wrote?
    end

    test "an owner's steer lifts the limits; their answer to a question doesn't" do
      asked = carrying([question("q_1", "c_1")])

      steered = Origin.of([asked, @user])
      assert steered.owner_wrote?
      refute steered.restricted?

      answered = Origin.of([asked, @answer])
      refute answered.owner_wrote?
      assert answered.restricted?
    end

    test "updates, schedules and the owner's own messages aren't restricted" do
      for sources <- [[carrying([update("c_1")])], [routine("blip")], [@user], [@answer], []] do
        refute Origin.of(sources).restricted?, inspect(sources)
      end
    end

    test "is total over anything" do
      for sources <- [nil, "no", [nil, 5, "x"], [%{"kind" => "signal", "signals" => "x"}]] do
        assert %{by: "unknown", restricted?: false, questions: []} = Origin.of(sources)
      end

      garbage = carrying([nil, 5, %{"kind" => "question", "question_id" => 7}])
      assert %{by: "thread", id: nil, questions: [%{question_id: nil}]} = Origin.of([garbage])
    end
  end

  describe "for_call/3" do
    setup do
      %{origin: Origin.of([carrying([question("q_1", "c_1"), question("q_2", "c_2")])])}
    end

    test "credits a question tool to the thread whose question it handles", %{origin: origin} do
      assert Origin.for_call(origin, "answer_question", %{"question_id" => "q_2"}) ==
               %{by: "thread", id: "c_2"}

      assert Origin.for_call(origin, "ask_owner", ~s({"question_id": "q_1"})) ==
               %{by: "thread", id: "c_1"}
    end

    test "falls back to the run's origin for anything else", %{origin: origin} do
      run = %{by: "thread", id: nil}
      assert Origin.for_call(origin, "read_thread", %{"thread" => "c_1"}) == run
      assert Origin.for_call(origin, "answer_question", %{"question_id" => "q_9"}) == run
      assert Origin.for_call(origin, "answer_question", "not json") == run
      assert Origin.for_call(origin, "ask_owner", %{"question_id" => 5}) == run
      assert Origin.for_call(origin, "ask_owner", nil) == run
      assert Origin.for_call(origin, "ask_owner", "[1, 2]") == run
      assert Origin.for_call(nil, "ask_owner", %{}) == %{by: "unknown", id: nil}
    end

    test "in an owner's run, other calls are the owner's" do
      origin = Origin.of([@user])
      assert Origin.for_call(origin, "start_thread", %{}) == %{by: "owner", id: nil}
    end
  end

  describe "unattended_ok?/3" do
    test "below the limit yes, at and above it no" do
      origin = Origin.of([carrying([update("c_1")])])
      assert Origin.unattended_ok?(origin, 9, 10)
      refute Origin.unattended_ok?(origin, 10, 10)
      refute Origin.unattended_ok?(origin, 11, 10)
    end

    test "always when the owner wrote to the run" do
      assert Origin.unattended_ok?(Origin.of([@user]), 50, 10)
    end
  end

  test "the refusals say what to do instead" do
    assert Origin.restricted_message() ==
             "A thread's question can't start or change work. " <>
               "Answer it with answer_question, or ask the user with ask_owner."

    assert Origin.unattended_message(10) ==
             "You've started or messaged threads 10 times since the user last wrote to you. " <>
               "Tell them what's going on and wait for them."
  end
end
