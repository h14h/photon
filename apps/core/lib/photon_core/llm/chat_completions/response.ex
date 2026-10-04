defmodule PhotonCore.LLM.ChatCompletions.Response do
  @moduledoc """
  The response half of the Chat Completions wire format, as pure functions.

  A `%Response{}` is a streamed answer as far as it has arrived: the token
  the stream folds into. Start with `new/0`, `feed/2` it each chunk of the
  body as it comes, then `finish/2` it for the result `PhotonCore.LLM.stream/3`
  returns. `feed/2` returns the events to report (text, reasoning and
  tool-call deltas) rather than reporting them, and its result doesn't
  depend on how the body was cut into chunks.

  Chunks of an unexpected shape are skipped, not raised on. An `"error"`
  chunk ends the stream, as does `[DONE]`; anything after is ignored.

  `to_sse/1` goes the other way: it renders a finished response as a
  stream, so a mock answer reaches a proxied node exactly as a provider's
  would. `http_error/3` reads a failed request's status, body and
  `retry-after` header into a `PhotonCore.LLM.Error`.
  """

  use Boundary,
    type: :strict,
    deps: [
      PhotonCore,
      PhotonCore.LLM.Error,
      PhotonCore.LLM.SSE,
      PhotonCore.LLM.ChatCompletions.Wire,
      Jason
    ]

  alias PhotonCore.LLM
  alias PhotonCore.LLM.ChatCompletions.Wire
  alias PhotonCore.LLM.{Error, SSE}
  alias PhotonCore.Message

  defstruct buffer: "",
            text: [],
            reasoning: [],
            calls: %{},
            usage: nil,
            finish: nil,
            model: nil,
            error: nil,
            done: false,
            events: []

  @typedoc """
  A streamed answer in progress. `text`, `reasoning` and each call's `args`
  are iodata; `calls` is keyed by the provider's call index; `events` holds
  the events of the chunk being fed, newest first.
  """
  @type t :: %__MODULE__{
          buffer: String.t(),
          text: iodata(),
          reasoning: iodata(),
          calls: %{
            non_neg_integer() => %{id: String.t() | nil, name: String.t() | nil, args: iodata()}
          },
          usage: map() | nil,
          finish: String.t() | nil,
          model: String.t() | nil,
          error: term(),
          done: boolean(),
          events: [LLM.event()]
        }

  @typedoc "Makes an ID for a call the provider sent without one, from its index."
  @type call_id :: (non_neg_integer() -> String.t())

  @doc "A response before any of the body has arrived."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Reads the next chunk of the body: returns the response so far and the
  events the chunk produced, in order.
  """
  @spec feed(t(), String.t()) :: {t(), [LLM.event()]}
  def feed(%__MODULE__{done: true} = response, _chunk), do: {response, []}

  def feed(%__MODULE__{} = response, chunk) do
    {payloads, buffer} = SSE.parse(response.buffer, chunk)
    response = Enum.reduce(payloads, %{response | buffer: buffer}, &read_payload(&2, &1))
    {%{response | events: []}, Enum.reverse(response.events)}
  end

  defp read_payload(%{done: true} = response, _payload), do: response
  defp read_payload(response, "[DONE]"), do: %{response | done: true}
  defp read_payload(response, payload), do: read_chunk(response, Jason.decode(payload))

  defp read_chunk(response, {:ok, %{"error" => error}}) when error != nil,
    do: %{response | error: error, done: true}

  defp read_chunk(response, {:ok, chunk}) when is_map(chunk) do
    response
    |> note_model(chunk["model"])
    |> note_usage(chunk["usage"])
    |> read_choices(Wire.list(chunk["choices"]))
  end

  defp read_chunk(response, _not_a_chunk), do: response

  defp note_model(%{model: nil} = response, model),
    do: %{response | model: Wire.text_or_nil(model)}

  defp note_model(response, _model), do: response

  defp note_usage(response, usage) when is_map(usage), do: %{response | usage: usage}
  defp note_usage(response, _usage), do: response

  defp read_choices(response, choices), do: Enum.reduce(choices, response, &read_choice(&2, &1))

  defp read_choice(response, %{} = choice) do
    response
    |> read_delta(choice["delta"])
    |> note_finish(choice["finish_reason"])
  end

  defp read_choice(response, _choice), do: response

  defp note_finish(response, reason) when is_binary(reason), do: %{response | finish: reason}
  defp note_finish(response, _reason), do: response

  defp read_delta(response, %{} = delta) do
    response
    |> add_text(delta["content"])
    |> add_reasoning(reasoning_text(delta))
    |> add_tool_call_deltas(Wire.list(delta["tool_calls"]))
  end

  defp read_delta(response, _delta), do: response

  # DeepSeek and Fireworks say reasoning_content; OpenRouter says reasoning.
  defp reasoning_text(delta),
    do: Wire.text_or_nil(delta["reasoning_content"]) || Wire.text_or_nil(delta["reasoning"])

  defp add_text(response, text) when is_binary(text) and text != "" do
    %{response | text: [response.text, text]} |> emit({:text, text})
  end

  defp add_text(response, _text), do: response

  defp add_reasoning(response, text) when is_binary(text) and text != "" do
    %{response | reasoning: [response.reasoning, text]} |> emit({:reasoning, text})
  end

  defp add_reasoning(response, _text), do: response

  defp add_tool_call_deltas(response, deltas),
    do: Enum.reduce(deltas, response, &add_tool_call_delta(&2, &1))

  # A call's first delta usually carries its ID and name; later ones add
  # argument text to the call at the same index.
  defp add_tool_call_delta(response, %{} = delta) do
    index = call_index(delta["index"], response.calls)
    function = function_fields(delta["function"])
    id = Wire.text_or_nil(delta["id"])
    name = Wire.text_or_nil(function["name"])
    args = Wire.arguments_text(function["arguments"]) || ""

    calls =
      Map.update(
        response.calls,
        index,
        new_call(id, name, args),
        &extend_call(&1, id, name, args)
      )

    %{response | calls: calls} |> emit({:tool_call, index, name, args})
  end

  defp add_tool_call_delta(response, _delta), do: response

  defp call_index(index, _calls) when is_integer(index) and index >= 0, do: index
  defp call_index(_index, calls), do: map_size(calls)

  defp function_fields(function) when is_map(function), do: function
  defp function_fields(_function), do: %{}

  defp new_call(id, name, args), do: %{id: id, name: name, args: [args]}

  defp extend_call(call, id, name, args),
    do: %{call | id: call.id || id, name: call.name || name, args: [call.args, args]}

  defp emit(response, event), do: %{response | events: [event | response.events]}

  @doc """
  The result once the body has ended: `{:ok, response}` as described in
  `PhotonCore.LLM`, or `{:error, error}` when the provider sent an error
  chunk or the stream ended without an answer (both retryable). `call_id`
  names calls the provider sent without an ID.
  """
  @spec finish(t(), call_id()) :: {:ok, LLM.response()} | {:error, Error.t()}
  def finish(%__MODULE__{error: error}, _call_id) when error != nil,
    do: {:error, Error.new(:stream, error_message(error), retryable: true)}

  def finish(%__MODULE__{} = response, call_id) do
    answer(response, assistant_message(response, call_id))
  end

  defp answer(%{finish: nil}, %{"content" => [], "tool_calls" => []}) do
    {:error, Error.new(:stream, "the response stream ended without an answer", retryable: true)}
  end

  defp answer(response, message) do
    {:ok,
     %{
       "message" => message,
       "stop" => stop_reason(response.finish, message["tool_calls"]),
       "usage" => usage(response.usage),
       "model" => response.model
     }}
  end

  defp assistant_message(response, call_id) do
    %{
      "role" => "assistant",
      "content" => Message.parts(IO.iodata_to_binary(response.text)),
      "reasoning" => blank_to_nil(IO.iodata_to_binary(response.reasoning)),
      "tool_calls" => tool_calls(response.calls, call_id)
    }
  end

  defp tool_calls(calls, call_id) do
    calls
    |> Enum.sort_by(fn {index, _call} -> index end)
    |> Enum.map(fn {index, call} ->
      %{
        "id" => call.id || call_id.(index),
        "name" => call.name || "",
        "arguments" => IO.iodata_to_binary(call.args)
      }
    end)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(message) when is_binary(message), do: message
  defp error_message(other), do: Jason.encode!(other)

  defp stop_reason(_, [_ | _]), do: "tool_use"
  defp stop_reason("stop", _), do: "end_turn"
  defp stop_reason("length", _), do: "max_tokens"
  defp stop_reason("content_filter", _), do: "refused"
  defp stop_reason(nil, _), do: "end_turn"
  defp stop_reason(other, _), do: other

  @doc "Token counts from a provider's `usage` object; missing counts are 0."
  @spec usage(map() | nil) :: %{String.t() => non_neg_integer()}
  def usage(nil), do: %{"input" => 0, "cached" => 0, "output" => 0, "reasoning" => 0}

  def usage(usage) do
    %{
      "input" => count(usage["prompt_tokens"]),
      "cached" => count(details(usage["prompt_tokens_details"])["cached_tokens"]),
      "output" => count(usage["completion_tokens"]),
      "reasoning" => count(details(usage["completion_tokens_details"])["reasoning_tokens"])
    }
  end

  defp details(%{} = details), do: details
  defp details(_details), do: %{}

  defp count(n) when is_integer(n) and n >= 0, do: n
  defp count(_n), do: 0

  ## Failed requests

  @doc """
  The error for a request the provider answered with a status other than
  200: the provider's message from `body` when it sent JSON, else the start
  of the body. Rate limits, timeouts, conflicts and server errors are
  retryable; `retry_after` is read from the `retry-after` header's values
  (whole seconds, not negative; anything else is ignored).
  """
  @spec http_error(non_neg_integer(), String.t(), [String.t()]) :: Error.t()
  def http_error(status, body, retry_after_values) do
    message = body |> Jason.decode() |> provider_message(body) |> or_no_details()

    Error.new(:http, message,
      status: status,
      retryable: retryable_status?(status),
      retry_after: retry_after_ms(retry_after_values)
    )
  end

  defp provider_message({:ok, %{"error" => %{"message" => message}}}, _body), do: message
  defp provider_message({:ok, %{"error" => message}}, _body) when is_binary(message), do: message

  defp provider_message({:ok, %{"message" => message}}, _body) when is_binary(message),
    do: message

  defp provider_message(_decoded, body), do: body |> String.trim() |> String.slice(0, 500)

  defp or_no_details(""), do: "no details"
  defp or_no_details(message), do: message

  # Timeouts, conflicts, rate limits and server errors may pass.
  defp retryable_status?(status), do: status in [408, 409, 425, 429] or status >= 500

  defp retry_after_ms([value | _]), do: value |> Integer.parse() |> whole_seconds_in_ms()
  defp retry_after_ms([]), do: nil

  # A negative value isn't a wait anyone can honor (and `Process.sleep/1`
  # raises on it), so it counts as absent, like any other malformed value.
  defp whole_seconds_in_ms({seconds, ""}) when seconds >= 0, do: seconds * 1000
  defp whole_seconds_in_ms(_not_whole_seconds), do: nil

  ## Rendering

  @doc """
  Renders a finished response as a Chat Completions SSE stream (iodata), so
  a mock answer reaches a proxied node exactly as a provider's would.
  """
  @spec to_sse(LLM.response()) :: iolist()
  def to_sse(%{"message" => message} = response) do
    calls = Message.tool_calls(message)

    chunks =
      Enum.concat([
        content_chunks(Message.text_of(message)),
        tool_call_chunks(calls),
        [last_chunk(response, calls)]
      ])

    [Enum.map(chunks, &["data: ", Jason.encode!(&1), "\n\n"]), "data: [DONE]\n\n"]
  end

  defp content_chunks(""), do: []
  defp content_chunks(text), do: [choice_chunk(%{"role" => "assistant", "content" => text})]

  defp tool_call_chunks(calls) do
    calls
    |> Enum.with_index()
    |> Enum.map(fn {call, index} ->
      choice_chunk(%{"tool_calls" => [tool_call_delta(call, index)]})
    end)
  end

  defp tool_call_delta(call, index) do
    %{
      "index" => index,
      "id" => call["id"],
      "type" => "function",
      "function" => %{"name" => call["name"], "arguments" => call["arguments"]}
    }
  end

  defp choice_chunk(delta), do: %{"choices" => [%{"index" => 0, "delta" => delta}]}

  defp last_chunk(response, calls) do
    usage = response["usage"] || %{}

    %{
      "model" => response["model"],
      "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => finish_reason(calls)}],
      "usage" => %{
        "prompt_tokens" => usage["input"] || 0,
        "completion_tokens" => usage["output"] || 0
      }
    }
  end

  defp finish_reason([]), do: "stop"
  defp finish_reason(_calls), do: "tool_calls"
end
