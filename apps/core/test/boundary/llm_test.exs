defmodule PhotonCore.LLMTest do
  @moduledoc """
  The boundary, tested the way the hub and nodes use it: `PhotonCore.LLM.stream/3`
  against a stub API over `Req.Test`. What the wire formats mean is covered
  by the core tests; these check the request that goes out, the events that
  come back, retries and errors.
  """

  use PhotonCore.Case, async: true

  alias PhotonCore.{EchoScript, StubProvider}

  defp answering_api(_context) do
    events = [
      reasoning_delta("think"),
      text_delta("Hel"),
      text_delta("lo"),
      call_added(1, "c1", "Bash"),
      arguments_delta(1, ~s({"co)),
      arguments_delta(1, ~s(mmand":"ls"})),
      item_done(1, %{
        "type" => "function_call",
        "call_id" => "c1",
        "name" => "Bash",
        "arguments" => ~s({"command":"ls"})
      }),
      completed(usage: usage(10, 5))
    ]

    StubProvider.streams(__MODULE__, sse_body(events))
    %{config: stub_config(__MODULE__)}
  end

  defp failing_then_answering_api(_context) do
    slow_down = {429, ~s({"error":{"message":"slow down"}}), [{"retry-after", "0"}]}
    answer = {:stream, sse_body([text_delta("ok"), completed()])}
    StubProvider.answers(__MODULE__, [slow_down, slow_down, answer])
    %{config: stub_config(__MODULE__)}
  end

  describe "ChatGPT streaming an answer" do
    setup :answering_api

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

    test "sends the conversation, the instructions and the token", %{config: config} do
      assert {:ok, _} = LLM.stream(request(), config)

      assert_received {:provider_request, %{body: body, headers: headers}}
      assert body["instructions"] == "Be brief."
      assert [%{"role" => "user", "content" => [%{"text" => "hi"}]}] = body["input"]
      assert %{"stream" => true, "store" => false} = body
      assert {"authorization", "Bearer k"} in headers
    end

    test "sends the config's extra headers", %{config: config} do
      config = Map.put(config, :headers, [{"x-photon", "1"}])
      assert {:ok, _} = LLM.stream(request(), config)

      assert_received {:provider_request, %{headers: headers}}
      assert {"x-photon", "1"} in headers
    end
  end

  describe "ChatGPT leaving a tool call unnamed" do
    test "gets it a name unique in the conversation" do
      events = [call_added(1, nil, "Bash", "{}"), completed()]
      StubProvider.streams(__MODULE__, sse_body(events))

      assert {:ok, %{"message" => %{"tool_calls" => [%{"id" => "call_0_" <> _}]}}} =
               LLM.stream(request(), stub_config(__MODULE__))
    end
  end

  describe "ChatGPT failing, then answering" do
    setup :failing_then_answering_api

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

  describe "an API that asks for a negative retry-after" do
    test "is retried with the usual backoff instead of crashing the caller" do
      slow_down = {429, ~s({"error":{"message":"slow down"}}), [{"retry-after", "-3"}]}
      answer = {:stream, sse_body([text_delta("ok"), completed()])}
      StubProvider.answers(__MODULE__, [slow_down, answer])

      assert {{:ok, %{"stop" => "end_turn"}}, [{:retry, 1, delay, %Error{retry_after: nil}} | _]} =
               capture_events(&LLM.stream(request(), stub_config(__MODULE__), &1))

      assert delay >= 1
    end
  end

  describe "ChatGPT failing for good" do
    test "does not retry client errors" do
      StubProvider.answers(__MODULE__, [
        {401, ~s({"error":{"message":"Your session has expired."}})}
      ])

      assert {{:error, %Error{status: 401, retryable: false} = error}, []} =
               capture_events(&LLM.stream(request(), stub_config(__MODULE__), &1))

      assert Exception.message(error) =~ "expired"
    end

    test "does not retry a plan whose usage is spent" do
      StubProvider.answers(__MODULE__, [
        {429, ~s({"error":{"code":"usage_limit_reached","message":"You've hit your limit."}})}
      ])

      assert {:error, %Error{status: 429, retryable: false}} =
               LLM.stream(request(), stub_config(__MODULE__))
    end

    test "a server error with no body says so" do
      StubProvider.answers(__MODULE__, [{500, ""}])
      config = stub_config(__MODULE__, max_attempts: 1)

      assert {:error, %Error{status: 500, message: "no details", retryable: true}} =
               LLM.stream(request(), config)
    end

    test "a dropped connection is a retryable transport error" do
      StubProvider.answers(__MODULE__, [:drop])
      config = stub_config(__MODULE__, max_attempts: 1)

      assert {:error, %Error{kind: :transport, retryable: true}} = LLM.stream(request(), config)
    end
  end

  describe "a request that can't be sent" do
    test "fails without a token, a model or a known provider, before calling anyone" do
      assert {:error, %Error{kind: :config, message: "not signed in with ChatGPT"}} =
               LLM.stream(request(), stub_config(__MODULE__, api_key: nil))

      assert {:error, %Error{kind: :config, message: "no model selected"}} =
               LLM.stream(request(model: ""), stub_config(__MODULE__))

      assert {:error, %Error{kind: :config}} = LLM.stream(request(), %{provider: "fireworks"})
      refute_received {:provider_request, _}
    end
  end

  describe "the hub's relay" do
    defp relay_config(overrides \\ []),
      do: stub_config(__MODULE__, [provider: "relay", api_key: "node-token"] ++ overrides)

    test "streams the hub's events into the result, and sends the node's token" do
      body = [
        Relay.event({:text, "Hel"}),
        Relay.keep_alive(),
        Relay.event({:tool_call, 0, "Bash", "{}"}),
        Relay.done(%{"message" => Message.assistant("Hello"), "stop" => "end_turn"})
      ]

      StubProvider.streams(__MODULE__, IO.iodata_to_binary(body))

      assert {{:ok, %{"stop" => "end_turn"}}, [{:text, "Hel"}, {:tool_call, 0, "Bash", "{}"}]} =
               capture_events(&LLM.stream(request(), relay_config(), &1))

      assert_received {:provider_request, %{body: body, headers: headers}}
      assert body["system"] == "Be brief."
      assert {"authorization", "Bearer node-token"} in headers
    end

    test "an error the hub reports isn't retried again" do
      error = Error.new(:http, "not signed in", status: 503, retryable: true)
      StubProvider.streams(__MODULE__, IO.iodata_to_binary(Relay.error(error)))

      assert {{:error, %Error{message: "not signed in", retryable: false}}, []} =
               capture_events(&LLM.stream(request(), relay_config(), &1))
    end

    test "the hub refusing the request keeps its reason" do
      refusal = Jason.encode!(%{"error" => Relay.encode_error(Error.new(:config, "bad token"))})
      StubProvider.answers(__MODULE__, [{401, refusal}])

      assert {:error, %Error{status: 401, message: "bad token", retryable: false}} =
               LLM.stream(request(), relay_config())
    end

    test "a hub that can't be reached is retried" do
      StubProvider.answers(__MODULE__, [{502, ""}, :drop])

      assert {{:error, %Error{kind: :transport}}, [{:retry, 1, _, %Error{status: 502}}]} =
               capture_events(&LLM.stream(request(), relay_config(max_attempts: 2), &1))
    end
  end

  describe "the mock provider" do
    test "the mock provider streams a scripted answer" do
      assert {{:ok, %{"message" => message, "stop" => "end_turn"}}, [{:text, "you "} | _]} =
               capture_events(&LLM.stream(request(), %{provider: "mock", script: EchoScript}, &1))

      assert Message.text_of(message) == "you said hi"
    end

    test "needs no model or token" do
      config = %{provider: "mock", script: EchoScript}
      assert {:ok, %{"model" => "mock-model"}} = LLM.stream(request(model: nil), config)
    end
  end
end
