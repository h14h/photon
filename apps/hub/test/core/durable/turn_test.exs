defmodule Photon.Durable.TurnTest do
  @moduledoc "A generation's turn: the request it sends, and what its answer leads to."

  use Photon.Case, async: true

  alias PhotonCore.LLM.Error

  @llm %{config: %{provider: "mock"}, model: "test-model", reasoning: "low"}

  describe "the request" do
    test "carries the model, system prompt, tools and the transcript as messages" do
      entries = [user_entry("hi", seq: 1), assistant_entry("hello", [], id: "e_2", seq: 2)]
      request = Turn.request(@llm, "be brief", entries, [Photon.TestProfile.Wait])

      assert request.model == "test-model"
      assert request.system == "be brief"
      assert request.reasoning == "low"
      assert request.messages == Context.messages(entries)
      assert [%{"name" => "wait", "description" => _, "parameters" => _}] = request.tools
    end

    test "counts tool rounds from one" do
      assert Turn.round(%{}) == 1
      assert Turn.round(%{"rounds" => 4}) == 5
    end

    test "stores the response with its usage, model and stop reason" do
      response = response(Message.assistant("hi"))

      assert Turn.assistant_entry(response) == %{
               "message" => Message.assistant("hi"),
               "usage" => %{"input" => 10, "output" => 5},
               "model" => "test",
               "stop" => "stop"
             }
    end
  end

  describe "an answer" do
    test "without tool calls answers the run" do
      assert Turn.outcome(response(Message.assistant("done")), 1) == :answer
    end

    test "with tool calls starts a tool round" do
      calls = [call("wait", %{}, "c1"), call("wait", %{}, "c2")]
      assert Turn.outcome(response(Message.assistant("", calls)), 1) == {:tool_round, calls}
    end

    test "with tool calls in the last round hits the round limit" do
      calls = [call("wait")]
      max = Turn.max_rounds()

      assert Turn.outcome(response(Message.assistant("", calls)), max - 1) == {:tool_round, calls}
      assert Turn.outcome(response(Message.assistant("", calls)), max) == {:round_limit, calls}
    end
  end

  describe "a tool round" do
    test "makes a tool task per call, owned by the generation" do
      assert Turn.tool_task(task(id: "t_9"), call("wait")) == %{
               kind: "tool",
               conversation_id: "c_1",
               owner_task_id: "t_9",
               phase: "run",
               input: %{"call" => call("wait")}
             }
    end

    test "waits until all of them settle, then goes on after the tools" do
      assert Turn.wait_for_tools(["t_2", "t_3"], %{"rounds" => 1}) ==
               {:wait, %{"on" => ["t_2", "t_3"], "policy" => "all_settled"}, "after_tools",
                %{"rounds" => 1}}
    end

    test "then requests again, with the steers placed meanwhile" do
      assert Turn.after_tools(%{"submissions" => ["s_1"], "rounds" => 1}, ["s_2"]) ==
               {:next, "request", %{"submissions" => ["s_1", "s_2"], "rounds" => 1}}

      assert Turn.after_tools(%{}, ["s_2"]) == {:next, "request", %{"submissions" => ["s_2"]}}
    end
  end

  describe "the round limit (Durable F8)" do
    test "gives every stored call a result, and stops without an answer" do
      max = Turn.max_rounds()

      assert %{
               "message" => %{"role" => "tool", "tool_call_id" => "call_1"} = result,
               "name" => "wait",
               "status" => "error",
               "details" => %{}
             } = Turn.not_run(call("wait"))

      assert Message.text_of(result) == "Not run: the assistant stopped after #{max} tool rounds."

      assert Turn.round_limit() ==
               {%{"message" => "Stopped after #{max} tool rounds without an answer."},
                "too many tool rounds", {:fail, "too many tool rounds"}}
    end
  end

  describe "settling" do
    test "an answered submission points at its answer; any other ends unanswered" do
      assert Turn.settlement("done", "e_7") == [status: "done", answer_entry_id: "e_7"]
      assert Turn.settlement("unanswered", "stopped") == [status: "unanswered", reason: "stopped"]
    end

    test "the inbox's next input starts the next run with a fresh round count" do
      assert Turn.next_run(["s_2"]) ==
               {:next, "request", %{"submissions" => ["s_2"], "rounds" => 0}}
    end

    test "errors the transcript shows" do
      assert Turn.request_failed("HTTP 500") == %{"message" => "HTTP 500"}
      assert Turn.stopped() == %{"message" => "Stopped.", "stopped" => true}
      assert Turn.failed("boom") == %{"message" => "The assistant failed: boom"}
    end
  end

  describe "usage" do
    test "is totalled per model, counting requests" do
      doc = Turn.add_usage(%{}, response())
      assert doc == %{"test" => %{"input" => 10, "output" => 5, "requests" => 1}}

      assert Turn.add_usage(doc, response(Message.assistant("x"), %{"usage" => %{"input" => 1}})) ==
               %{"test" => %{"input" => 11, "output" => 5, "requests" => 2}}
    end

    test "of a response without a model goes under unknown" do
      assert %{"unknown" => %{"requests" => 1}} =
               Turn.add_usage(%{}, response(Message.assistant("x"), %{"model" => nil}))
    end
  end

  describe "live events" do
    test "are the stream's events as watchers see them" do
      assert Turn.live_event({:text, "he"}) == %{"type" => "text", "delta" => "he"}
      assert Turn.live_event({:reasoning, "hm"}) == %{"type" => "reasoning", "delta" => "hm"}

      assert Turn.live_event({:web_search, "ws_1", nil}) ==
               %{"type" => "web_search", "id" => "ws_1", "action" => nil}

      assert Turn.live_event({:tool_call, 0, "wait", "{"}) ==
               %{"type" => "tool_call", "index" => 0, "name" => "wait", "delta" => "{"}

      error = Error.new(:http, "HTTP 503")

      assert Turn.live_event({:retry, 2, 500, error}) ==
               %{"type" => "retry", "attempt" => 2, "delay_ms" => 500, "message" => "HTTP 503"}
    end
  end
end
