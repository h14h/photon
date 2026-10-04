defmodule PhotonCore.LLM.MockTest do
  use PhotonCore.Case, async: true

  alias PhotonCore.EchoScript

  defp mock(prompt) do
    capture_events(
      &Mock.stream(request(messages: [Message.user(prompt)]), %{script: EchoScript}, &1)
    )
  end

  describe "stream/3 with a script" do
    test "the mock provider streams a scripted answer" do
      assert {{:ok, %{"message" => message, "stop" => "end_turn"}}, events} = mock("hi")

      assert Message.text_of(message) == "you said hi"
      assert events == [{:text, "you "}, {:text, "said "}, {:text, "hi"}]
    end

    test "fills in the assistant fields a script leaves out" do
      assert {{:ok, %{"message" => message}}, _events} = mock("hi")
      assert %{"role" => "assistant", "reasoning" => nil, "tool_calls" => []} = message
    end

    test "streams tool calls after the text and stops for tool use" do
      assert {{:ok, %{"stop" => "tool_use", "model" => "mock-model"}}, events} = mock("call Bash")
      assert events == [{:text, "Calling."}, {:tool_call, 0, "Bash", ~s({"x":1})}]
    end

    test "estimates usage at four bytes per token" do
      request = request(system: "1234", messages: [Message.user("hi")])

      {:ok, %{"usage" => usage, "message" => message}} =
        Mock.stream(request, %{script: EchoScript}, fn _event -> :ok end)

      input_bytes = byte_size(Jason.encode!(request.messages)) + 4
      assert usage["input"] == div(input_bytes, 4)
      assert usage["output"] == div(byte_size(Jason.encode!(message)), 4)
      assert usage["cached"] == 0 and usage["reasoning"] == 0
    end

    test "a script's error is a non-retryable HTTP 500" do
      assert {{:error, %Error{kind: :http, status: 500, retryable: false}}, []} = mock("fail")
    end

    test "needs a script" do
      assert_raise ArgumentError, fn -> Mock.stream(request(), %{}, fn _event -> :ok end) end
    end
  end

  describe "helpers for scripts" do
    test "last_user_text and since_user read from the latest prompt" do
      after_prompt = [Message.assistant("ran"), Message.tool_result("c1", "out")]
      request = request(messages: [Message.user("one"), Message.user("two") | after_prompt])

      assert Mock.last_user_text(request) == "two"
      assert Mock.since_user(request) == after_prompt
      assert Mock.last_user_text(request(messages: [])) == ""
    end

    test "call/2 encodes its arguments and gets a fresh ID each time" do
      assert %{"id" => "call_" <> _, "name" => "Bash", "arguments" => ~s({"command":"ls"})} =
               call = Mock.call("Bash", %{"command" => "ls"})

      refute Mock.call("Bash", %{})["id"] == call["id"]
    end
  end
end
