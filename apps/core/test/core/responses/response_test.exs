defmodule PhotonCore.Responses.ResponseTest do
  @moduledoc "The Responses event stream, folded into one assistant message."

  use PhotonCore.Case, async: true

  test "text, reasoning and a tool call fold into one message, with their events" do
    reasoning = %{"type" => "reasoning", "id" => "rs_1", "encrypted_content" => "x"}

    body =
      sse_body([
        reasoning_delta("First."),
        summary_part_added(),
        reasoning_delta("Second."),
        item_done(0, reasoning),
        text_delta("Hi"),
        call_added(1, "c1", "Bash"),
        arguments_delta(1, "{}"),
        completed(model: "gpt-6.1-sol", usage: usage(10, 4, 6, 2))
      ])

    assert {{:ok, response}, events} = read_stream([body])

    assert response["message"] == %{
             "role" => "assistant",
             "content" => [Message.text("Hi")],
             "reasoning" => "First.\n\nSecond.",
             "tool_calls" => [%{"id" => "c1", "name" => "Bash", "arguments" => "{}"}],
             "reasoning_items" => [reasoning]
           }

    assert response["stop"] == "tool_use"
    assert response["model"] == "gpt-6.1-sol"
    assert response["usage"] == %{"input" => 10, "cached" => 6, "output" => 4, "reasoning" => 2}

    assert events == [
             {:reasoning, "First."},
             {:reasoning, "\n\n"},
             {:reasoning, "Second."},
             {:text, "Hi"},
             {:tool_call, 0, "Bash", ""},
             {:tool_call, 0, nil, "{}"}
           ]
  end

  test "web searches the API ran are reported as they start and finish, and kept in order" do
    reasoning = %{"type" => "reasoning", "id" => "rs_1", "encrypted_content" => "x"}

    search = %{
      "type" => "web_search_call",
      "id" => "ws_1",
      "status" => "completed",
      "action" => %{"type" => "search", "query" => "elixir release", "queries" => ["elixir"]}
    }

    page = %{
      "type" => "web_search_call",
      "id" => "ws_2",
      "status" => "completed",
      "action" => %{"type" => "open_page", "url" => "https://github.com/elixir-lang/elixir"}
    }

    body =
      sse_body([
        item_done(0, reasoning),
        %{
          "type" => "response.output_item.added",
          "output_index" => 1,
          "item" => %{"type" => "web_search_call", "id" => "ws_1", "status" => "in_progress"}
        },
        %{"type" => "response.web_search_call.searching", "item_id" => "ws_1"},
        item_done(1, search),
        item_done(2, page),
        text_delta("v1.20.4."),
        completed()
      ])

    assert {{:ok, response}, events} = read_stream([body])
    assert response["message"]["reasoning_items"] == [reasoning, search, page]
    assert response["stop"] == "end_turn"

    assert events == [
             {:web_search, "ws_1", nil},
             {:web_search, "ws_1", %{"type" => "search", "query" => "elixir release"}},
             {:web_search, "ws_2",
              %{"type" => "open_page", "url" => "https://github.com/elixir-lang/elixir"}},
             {:text, "v1.20.4."}
           ]
  end

  test "a finished call's arguments win over its deltas, and an unnamed call gets a name" do
    body =
      sse_body([
        call_added(3, nil, "Bash"),
        arguments_delta(3, "{\"a\""),
        item_done(3, %{"type" => "function_call", "name" => "Bash", "arguments" => "{\"a\":1}"}),
        completed()
      ])

    assert {{:ok, %{"message" => %{"tool_calls" => [call]}}}, _events} = read_stream([body])
    assert call == %{"id" => "call_0", "name" => "Bash", "arguments" => "{\"a\":1}"}
  end

  test "a call made in a namespace keeps it, to hand back" do
    item = %{
      "type" => "function_call",
      "call_id" => "c1",
      "name" => "Bash",
      "namespace" => "functions",
      "arguments" => "{}"
    }

    body = sse_body([item_done(1, item), completed()])

    assert {{:ok, %{"message" => %{"tool_calls" => [%{"namespace" => "functions"}]}}}, _} =
             read_stream([body])
  end

  test "a call named with its namespace is read as the tool's name in it" do
    body = sse_body([call_added(1, "c1", "functions.Bash", "{}"), completed()])

    assert {{:ok, %{"message" => %{"tool_calls" => [call]}}}, [{:tool_call, 0, "Bash", "{}"}]} =
             read_stream([body])

    assert %{"name" => "Bash", "namespace" => "functions"} = call
  end

  test "raw reasoning text streams too, and output it doesn't need is skipped" do
    raw = %{"type" => "response.reasoning_text.delta", "delta" => "thinking"}
    message_item = %{"type" => "message", "content" => [%{"text" => "hi"}]}

    body =
      sse_body([
        raw,
        arguments_delta(9, "for a call that never started"),
        item_done(0, message_item),
        completed()
      ])

    assert {{:ok, response}, [{:reasoning, "thinking"}]} = read_stream([body])
    assert response["message"]["reasoning"] == "thinking"
    assert response["message"]["tool_calls"] == []
  end

  test "an answer cut short says why" do
    assert {{:ok, %{"stop" => "max_tokens"}}, _} =
             read_stream([sse_body([text_delta("a"), incomplete("max_output_tokens")])])

    assert {{:ok, %{"stop" => "refused"}}, _} =
             read_stream([sse_body([incomplete("content_filter")])])
  end

  test "a failure ends the stream as an error; server trouble is worth a retry" do
    assert {{:error, %Error{retryable: true, message: "overloaded"}}, _} =
             read_stream([sse_body([failed("server_error", "overloaded")])])

    assert {{:error, %Error{retryable: false}}, _} =
             read_stream([sse_body([failed("invalid_prompt", "no"), text_delta("ignored")])])

    error = %{
      "type" => "error",
      "error" => %{"code" => "rate_limit_exceeded", "message" => "slow"}
    }

    assert {{:error, %Error{retryable: true}}, _} = read_stream([sse_body([error])])

    odd = %{"type" => "error", "error" => "the server fell over"}
    assert {{:error, %Error{retryable: false} = e}, _} = read_stream([sse_body([odd])])
    assert e.message =~ "fell over"
  end

  test "a stream that ends without its last event is a retryable error" do
    assert {{:error, %Error{kind: :stream, retryable: true}}, [{:text, "a"}]} =
             read_stream([sse_body([text_delta("a")])])
  end

  test "events it doesn't know, or can't read, are skipped" do
    body = sse_body([%{"type" => "response.created"}, %{"type" => "response.output_text.delta"}])
    assert {{:error, _}, []} = read_stream([body <> "data: {not json\n\n"])
  end
end
