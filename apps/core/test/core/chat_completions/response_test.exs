defmodule PhotonCore.LLM.ChatCompletions.ResponseTest do
  @moduledoc """
  The streamed-response fold, fed bytes directly: no HTTP, no processes.
  """

  use PhotonCore.Case, async: true

  # The result of folding `chunks` sent as one body.
  defp result(chunks), do: chunks |> sse_body() |> List.wrap() |> read_stream() |> elem(0)

  defp tool_call_answer(_context) do
    chunks = [
      delta_chunk(%{"reasoning_content" => "think"}, %{"model" => "m"}),
      text_chunk("Hel"),
      text_chunk("lo"),
      tool_call_chunk(
        index: 0,
        id: "c1",
        function: %{"name" => "Bash", "arguments" => "{\"co"}
      ),
      tool_call_chunk(index: 0, function: %{"arguments" => "mmand\":\"ls\"}"}),
      finish_chunk("tool_calls"),
      usage_chunk(10, 5),
      :done
    ]

    %{chunks: chunks, body: sse_body(chunks)}
  end

  describe "a well-formed answer" do
    setup :tool_call_answer

    test "folds text, reasoning and tool calls into one message", %{body: body} do
      assert {{:ok, response}, _events} = read_stream([body])

      assert response["message"] == %{
               "role" => "assistant",
               "content" => [Message.text("Hello")],
               "reasoning" => "think",
               "tool_calls" => [
                 %{"id" => "c1", "name" => "Bash", "arguments" => ~s({"command":"ls"})}
               ]
             }

      assert response["stop"] == "tool_use"
      assert response["model"] == "m"
      assert response["usage"] == %{"input" => 10, "cached" => 0, "output" => 5, "reasoning" => 0}
    end

    test "reports each delta as an event, in order", %{body: body} do
      assert {_result, events} = read_stream([body])

      assert events == [
               {:reasoning, "think"},
               {:text, "Hel"},
               {:text, "lo"},
               {:tool_call, 0, "Bash", "{\"co"},
               {:tool_call, 0, nil, "mmand\":\"ls\"}"}
             ]
    end

    test "gives the same result and events however the body is cut", %{body: body} do
      whole = read_stream([body])

      for cut <- 1..(byte_size(body) - 1)//7 do
        assert read_stream(split_at(body, [cut])) == whole
      end
    end

    test "reads nothing after [DONE]", %{chunks: chunks} do
      {response, _events} = Response.feed(Response.new(), sse_body(chunks))
      assert {^response, []} = Response.feed(response, sse_body([text_chunk("late")]))
    end
  end

  describe "chunks of unexpected shapes" do
    # core-stream-raises-on-malformed-chunks
    test "chunks of an unexpected shape are skipped instead of raising" do
      assert {:error, _} = result([%{"choices" => 0}])
      assert {:error, _} = result([%{"choices" => [%{"delta" => "hi"}]}])
      assert {:error, _} = result([%{"choices" => %{"a" => 1}}, %{"usage" => [1]}])

      assert {:ok, %{"message" => %{"content" => [%{"text" => "ok"}]}, "stop" => "end_turn"}} =
               result([
                 %{"choices" => [%{"delta" => %{"content" => "ok"}, "finish_reason" => 1}]},
                 %{"choices" => [1, nil], "model" => 2, "usage" => %{"prompt_tokens" => "x"}}
               ])
    end

    test "tool-call arguments sent as an object become JSON text" do
      call = %{
        "index" => 0,
        "id" => "c1",
        "function" => %{"name" => "Bash", "arguments" => %{"command" => "ls"}}
      }

      assert {:ok, %{"message" => %{"tool_calls" => [tool_call]}}} =
               result([%{"choices" => [%{"delta" => %{"tool_calls" => [call]}}]}])

      assert tool_call == %{"id" => "c1", "name" => "Bash", "arguments" => ~s({"command":"ls"})}
    end

    test "an error chunk whose message isn't text still becomes an error" do
      assert {:error, error} = result([%{"error" => %{"message" => %{"nested" => true}}}])
      assert is_binary(error.message)
    end

    test "payloads that aren't JSON objects are ignored" do
      assert {:ok, %{"message" => %{"content" => [%{"text" => "ok"}]}}} =
               result(["not an object", 3, text_chunk("ok")])

      assert {{:ok, _}, [{:text, "ok"}]} =
               read_stream(["data: {garbage\n\n", sse_body([text_chunk("ok")])])
    end
  end

  describe "finish/2" do
    test "names calls the provider sent without an ID with the function it's given" do
      chunks = [tool_call_chunk(function: %{"name" => "a"}), tool_call_chunk(index: 4)]

      {response, _events} = Response.feed(Response.new(), sse_body(chunks))

      assert {:ok, %{"message" => %{"tool_calls" => [first, second]}}} =
               Response.finish(response, &"made_#{&1}")

      assert %{"id" => "made_0", "name" => "a", "arguments" => ""} = first
      assert %{"id" => "made_4", "name" => ""} = second
    end

    test "maps the provider's finish reason to a stop reason" do
      for {reason, stop} <- [
            {"stop", "end_turn"},
            {"length", "max_tokens"},
            {"content_filter", "refused"},
            {"other", "other"}
          ] do
        assert {:ok, %{"stop" => ^stop}} = result([text_chunk("x"), finish_chunk(reason)])
      end

      assert {:ok, %{"stop" => "end_turn"}} = result([text_chunk("x")])
    end

    test "a finish reason alone is an empty answer, but no answer at all is a retryable error" do
      assert {:ok, %{"message" => %{"content" => []}}} = result([finish_chunk("stop")])

      assert {:error, %Error{kind: :stream, retryable: true}} = result([])
    end

    test "an error chunk is a retryable stream error with the provider's message" do
      assert {:error, %Error{kind: :stream, retryable: true, message: "overloaded"}} =
               result([text_chunk("partial"), %{"error" => %{"message" => "overloaded"}}])

      assert {:error, %Error{message: "plain"}} = result([%{"error" => "plain"}])
    end

    test "usage reads cached and reasoning tokens and treats bad counts as 0" do
      usage = %{
        "prompt_tokens" => 7,
        "prompt_tokens_details" => %{"cached_tokens" => 3},
        "completion_tokens" => -1,
        "completion_tokens_details" => %{"reasoning_tokens" => 2}
      }

      assert Response.usage(usage) == %{
               "input" => 7,
               "cached" => 3,
               "output" => 0,
               "reasoning" => 2
             }
    end
  end

  describe "http_error/3" do
    test "takes the provider's message and marks rate limits and server errors retryable" do
      assert %Error{kind: :http, status: 429, retryable: true, message: "slow down"} =
               Response.http_error(429, ~s({"error":{"message":"slow down"}}), [])

      assert %Error{retryable: true, message: "busy"} =
               Response.http_error(503, ~s({"error":"busy"}), [])

      assert %Error{retryable: false, message: "nope"} =
               Response.http_error(400, ~s({"message":"nope"}), [])
    end

    test "falls back to the start of the body, or to 'no details'" do
      assert %Error{message: "Bad Gateway"} = Response.http_error(502, "  Bad Gateway\n", [])
      assert %Error{message: "no details"} = Response.http_error(500, "", [])

      assert %Error{message: message} = Response.http_error(500, String.duplicate("x", 900), [])
      assert String.length(message) == 500
    end

    test "reads retry-after as whole seconds" do
      assert %Error{retry_after: 2_000} = Response.http_error(429, "", ["2"])
      assert %Error{retry_after: nil} = Response.http_error(429, "", ["soon"])
      assert %Error{retry_after: nil} = Response.http_error(429, "", [])
    end

    test "ignores a negative retry-after, which no wait can honor" do
      assert %Error{retry_after: nil, retryable: true} = Response.http_error(429, "", ["-3"])
      assert %Error{retry_after: 0} = Response.http_error(429, "", ["0"])
    end
  end

  describe "to_sse/1" do
    test "renders an answer that reads back as the same message" do
      call = %{"id" => "c1", "name" => "Bash", "arguments" => ~s({"command":"ls"})}

      response = %{
        "message" => Message.assistant("Listing.", [call]),
        "model" => "mock-model",
        "usage" => %{"input" => 3, "output" => 4}
      }

      body = response |> Response.to_sse() |> IO.iodata_to_binary()
      assert String.ends_with?(body, "data: [DONE]\n\n")

      assert {{:ok, read}, _events} = read_stream([body])
      assert read["message"]["tool_calls"] == [call]
      assert read["stop"] == "tool_use"
      assert read["usage"]["input"] == 3
    end

    test "an answer without text or calls is just the finish chunk" do
      body =
        %{"message" => Message.assistant(""), "model" => nil}
        |> Response.to_sse()
        |> IO.iodata_to_binary()

      assert {{:ok, %{"stop" => "end_turn"}}, []} = read_stream([body])
    end
  end
end
