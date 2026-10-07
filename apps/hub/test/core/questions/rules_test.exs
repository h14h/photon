defmodule Photon.Questions.RulesTest do
  @moduledoc "The rules of an `ask_blip` question (section 4.2)."

  use Photon.Case, async: true

  alias Photon.Questions.Rules

  @question %{id: "q_456", thread_title: "Fix the pump"}

  describe "question/1 and answer/1" do
    test "trim, require text and cap the length" do
      assert Rules.question("  Which pump model?  ") == {:ok, "Which pump model?"}
      assert Rules.question("   ") == {:error, "Ask one specific question."}
      assert Rules.question(nil) == {:error, "Ask one specific question."}
      assert Rules.question(5) == {:error, "Ask one specific question."}
      assert {:ok, _} = Rules.question(String.duplicate("a", 2_000))

      assert Rules.question(String.duplicate("a", 2_001)) ==
               {:error,
                "Keep the question under 2,000 characters; put background in a context file and say which."}

      assert Rules.answer(" the second one ") == {:ok, "the second one"}
      assert Rules.answer("") == {:error, "Write an answer."}
      assert Rules.answer(nil) == {:error, "Write an answer."}
      assert {:ok, _} = Rules.answer(String.duplicate("a", 4_000))

      assert Rules.answer(String.duplicate("a", 4_001)) ==
               {:error, "Keep the answer under 4,000 characters."}
    end
  end

  describe "step/2" do
    test "from asked" do
      assert Rules.step("asked", {:answer, {:blip, false}}) == {:ok, "answered", "blip"}
      assert Rules.step("asked", {:answer, {:blip, true}}) == {:ok, "answered", "blip"}
      assert Rules.step("asked", {:pass, :blip}) == {:ok, "with_owner", nil}
      assert Rules.step("asked", {:pass, :hub}) == {:ok, "with_owner", nil}
      assert Rules.step("asked", {:answer, :owner}) == {:error, :with_blip}
      assert Rules.step("asked", :withdraw) == {:ok, "withdrawn", nil}
    end

    test "from with_owner: Blip's answer counts only when the owner wrote, and is theirs" do
      assert Rules.step("with_owner", {:answer, :owner}) == {:ok, "answered", "owner"}
      assert Rules.step("with_owner", {:answer, {:blip, true}}) == {:ok, "answered", "owner"}
      assert Rules.step("with_owner", {:answer, {:blip, false}}) == {:error, :with_owner}
      assert Rules.step("with_owner", {:pass, :blip}) == {:error, :already_passed}
      assert Rules.step("with_owner", {:pass, :hub}) == {:error, :already_passed}
      assert Rules.step("with_owner", :withdraw) == {:ok, "withdrawn", nil}
    end

    test "answered and withdrawn never change" do
      for event <- [{:answer, :owner}, {:answer, {:blip, true}}, {:pass, :blip}, {:pass, :hub}] do
        assert Rules.step("answered", event) == {:error, :answered}
        assert Rules.step("withdrawn", event) == {:error, :withdrawn}
      end

      assert Rules.step("answered", :withdraw) == {:ok, "answered", nil}
      assert Rules.step("withdrawn", :withdraw) == {:error, :withdrawn}
    end

    test "anything else is refused, not raised" do
      assert Rules.step(nil, :withdraw) == {:error, :invalid}
      assert Rules.step("asked", :shout) == {:error, :invalid}
      assert Rules.step("asked", {:pass, :thread}) == {:error, :invalid}
    end
  end

  describe "message/3" do
    test "Blip's words name the question by ID" do
      assert Rules.message(:with_owner, :blip, @question) ==
               "q_456 is with the user. Wait for their answer; it goes to the thread without you."

      assert Rules.message(:already_passed, :blip, @question) ==
               "You already asked the user about q_456."

      assert Rules.message(:answered, :blip, @question) == "q_456 was already answered."

      assert Rules.message(:withdrawn, :blip, @question) ==
               "q_456 was withdrawn: its thread was stopped."

      assert Rules.message(:not_found, :blip, %{id: "q_999"}) ==
               "There's no open question q_999."
    end

    test "the owner's words name the thread by title" do
      assert Rules.message(:with_blip, :owner, @question) ==
               ~s{Blip has "Fix the pump"'s question; it'll ask you if it needs to.}

      assert Rules.message(:answered, :owner, @question) ==
               ~s{"Fix the pump"'s question was already answered.}

      assert Rules.message(:withdrawn, :owner, @question) ==
               ~s{"Fix the pump" was stopped, so its question was withdrawn.}
    end

    test "every reason has words for both, and the owner's never show an ID" do
      reasons = [:with_owner, :already_passed, :with_blip, :answered, :withdrawn, :invalid]

      for reason <- [:not_found | reasons], audience <- [:blip, :owner] do
        assert is_binary(Rules.message(reason, audience, @question))
        assert is_binary(Rules.message(reason, audience, nil))
      end

      for reason <- [:not_found | reasons],
          question <- [@question, nil] do
        refute Rules.message(reason, :owner, question) =~ "q_"
      end
    end
  end

  describe "askable?/1" do
    test "only an unfinished task not marked for abort" do
      assert Rules.askable?(%{status: "running", abort_requested: false})
      assert Rules.askable?(%{status: "waiting", abort_requested: false})
      assert Rules.askable?(%{status: "pending", abort_requested: false})
      refute Rules.askable?(%{status: "running", abort_requested: true})
      refute Rules.askable?(%{status: "waiting", abort_requested: true})

      for status <- ~w(done failed aborted),
          do: refute(Rules.askable?(%{status: status, abort_requested: false}))

      refute Rules.askable?(nil)
    end
  end

  describe "escalate?/2" do
    test "an asked question whose carrier has settled, been withdrawn or gone" do
      asked = %{status: "asked"}

      for status <- ~w(done unanswered withdrawn),
          do: assert(Rules.escalate?(asked, %{status: status}))

      for status <- ~w(queued placed), do: refute(Rules.escalate?(asked, %{status: status}))
      assert Rules.escalate?(asked, nil)
    end

    test "never one Blip passed on, answered or withdrawn" do
      for status <- ~w(with_owner answered withdrawn),
          do: refute(Rules.escalate?(%{status: status}, %{status: "done"}))

      refute Rules.escalate?(nil, nil)
    end
  end

  describe "result/1" do
    test "Blip's answer" do
      assert Rules.result(%{answered_by: "blip", answer: "staging", wording: nil}) ==
               "Blip answered: staging"
    end

    test "the owner's answer, with how Blip put the question" do
      assert Rules.result(%{
               answered_by: "owner",
               answer: "the second one",
               wording: "Which pump should the thread order: the 40 W or the 60 W?"
             }) ==
               "Blip asked the user: Which pump should the thread order: the 40 W or the 60 W?\n" <>
                 "They answered: the second one"
    end

    test "the owner's answer to the thread's own words" do
      assert Rules.result(%{answered_by: "owner", answer: "yes", wording: nil}) ==
               "The user answered: yes"

      assert Rules.result(%{answered_by: "owner", answer: "yes", wording: ""}) ==
               "The user answered: yes"
    end
  end

  describe "open?/1" do
    test "asked and with_owner" do
      assert Rules.open?("asked")
      assert Rules.open?("with_owner")
      refute Rules.open?("answered")
      refute Rules.open?("withdrawn")
      refute Rules.open?(nil)
    end
  end
end
