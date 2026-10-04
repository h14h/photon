defmodule PhotonCore.LLMTest do
  @moduledoc """
  The boundary, tested the way the hub and nodes use it: `PhotonCore.LLM.stream/3`
  against a stub provider over `Req.Test`. What the wire format means is
  covered by the core tests; these check the request that goes out, the
  events that come back, retries and errors.
  """

  use PhotonCore.Case, async: true

  alias PhotonCore.{EchoScript, StubProvider}

  defp answering_provider(_context) do
    chunks = [
      delta_chunk(%{"reasoning_content" => "think"}, %{"model" => "m"}),
      text_chunk("Hel"),
      text_chunk("lo"),
      tool_call_chunk(index: 0, id: "c1", function: %{"name" => "Bash", "arguments" => "{\"co"}),
      tool_call_chunk(index: 0, function: %{"arguments" => "mmand\":\"ls\"}"}),
      finish_chunk("tool_calls"),
      usage_chunk(10, 5),
      :done
    ]

    StubProvider.streams(__MODULE__, sse_body(chunks))
    %{config: stub_config(__MODULE__)}
  end

  defp failing_then_answering_provider(_context) do
    slow_down = {429, ~s({"error":{"message":"slow down"}}), [{"retry-after", "0"}]}
    answer = {:stream, sse_body([text_chunk("ok"), finish_chunk("stop"), :done])}
    StubProvider.answers(__MODULE__, [slow_down, slow_down, answer])
    %{config: stub_config(__MODULE__)}
  end

  describe "a provider that streams an answer" do
    setup :answering_provider

    test "streams text, reasoning and tool calls into one message", %{config: config} do
      assert {{:ok, response}, events} = capture_events(&LLM.stream(request(), config, &1))

      assert response["message"]["content"] == [Message.text("Hello")]
      assert response["message"]["reasoning"] == "think"

      assert [%{"id" => "c1", "name" => "Bash", "arguments" => ~s({"command":"ls"})}] =
               response["message"]["tool_calls"]

      assert response["stop"] == "tool_use"
      assert response["usage"]["input"] == 10
      assert [{:reasoning, "think"}, {:text, "Hel"}, {:text, "lo"} | _] = events
    end

    test "sends the conversation and the key to the provider", %{config: config} do
      assert {:ok, _} = LLM.stream(request(), config)

      assert_received {:provider_request, %{body: body, headers: headers}}
      assert [%{"role" => "system"}, %{"role" => "user", "content" => "hi"}] = body["messages"]
      assert {"authorization", "Bearer k"} in headers
    end

    test "sends no authorization header without a key", %{config: config} do
      assert {:ok, _} = LLM.stream(request(), %{config | api_key: ""})

      assert_received {:provider_request, %{headers: headers}}
      refute List.keymember?(headers, "authorization", 0)
    end
  end

  describe "a provider that fails, then answers" do
    setup :failing_then_answering_provider

    test "retries retryable failures and reports them", %{config: config} do
      assert {{:ok, %{"stop" => "end_turn"}}, events} =
               capture_events(&LLM.stream(request(), config, &1))

      assert [
               {:retry, 1, 0, %Error{status: 429, message: "slow down"}},
               {:retry, 2, 0, %Error{}},
               {:text, "ok"}
             ] = events
    end

    test "gives up after max_attempts with the last error", %{config: config} do
      assert {{:error, %Error{status: 429, retryable: true}}, [{:retry, 1, 0, _}]} =
               capture_events(&LLM.stream(request(), Map.put(config, :max_attempts, 2), &1))
    end
  end

  describe "a provider that asks for a negative retry-after" do
    test "is retried with the usual backoff instead of crashing the caller" do
      slow_down = {429, ~s({"error":{"message":"slow down"}}), [{"retry-after", "-3"}]}
      answer = {:stream, sse_body([text_chunk("ok"), finish_chunk("stop"), :done])}
      StubProvider.answers(__MODULE__, [slow_down, answer])

      assert {{:ok, %{"stop" => "end_turn"}}, [{:retry, 1, delay, %Error{retry_after: nil}} | _]} =
               capture_events(&LLM.stream(request(), stub_config(__MODULE__), &1))

      assert delay >= 1
    end
  end

  describe "a provider that fails for good" do
    test "does not retry client errors" do
      StubProvider.answers(__MODULE__, [
        {401, ~s({"error":{"message":"The API key you provided is invalid."}})}
      ])

      assert {{:error, %Error{status: 401, retryable: false} = error}, []} =
               capture_events(&LLM.stream(request(), stub_config(__MODULE__), &1))

      assert Exception.message(error) =~ "invalid"
    end

    test "a dropped connection is a retryable transport error" do
      StubProvider.answers(__MODULE__, [:drop])
      config = stub_config(__MODULE__, max_attempts: 1)

      assert {:error, %Error{kind: :transport, retryable: true}} = LLM.stream(request(), config)
    end
  end

  describe "a request that can't be sent" do
    test "fails without a base URL or a model, before calling anyone" do
      assert {:error, %Error{kind: :config, message: "no base URL for provider custom"}} =
               LLM.stream(request(), %{provider: "custom"})

      assert {:error, %Error{kind: :config, message: "no model selected"}} =
               LLM.stream(request(model: ""), stub_config(__MODULE__))

      refute_received {:provider_request, _}
    end
  end

  describe "the mock provider" do
    test "the mock provider streams a scripted answer" do
      assert {{:ok, %{"message" => message, "stop" => "end_turn"}}, [{:text, "you "} | _]} =
               capture_events(&LLM.stream(request(), %{provider: "mock", script: EchoScript}, &1))

      assert Message.text_of(message) == "you said hi"
    end

    test "needs no model or base URL" do
      config = %{provider: "mock", script: EchoScript}
      assert {:ok, %{"model" => "mock-model"}} = LLM.stream(request(model: nil), config)
    end
  end
end
