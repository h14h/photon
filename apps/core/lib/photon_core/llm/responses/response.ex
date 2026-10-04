defmodule PhotonCore.LLM.Responses.Response do
  @moduledoc """
  The response half of the OpenAI Responses API, as pure functions: the
  event stream folds into one assistant message.

  Start with `new/0`, `feed/2` it each chunk of the body as it comes, then
  `finish/2` it for the result `PhotonCore.LLM.stream/3` returns. `feed/2`
  returns the events to report (text, reasoning summary and tool-call
  deltas) rather than reporting them, and its result doesn't depend on how
  the body was cut into chunks.

  The events it reads:

    * `response.output_text.delta`: answer text
    * `response.reasoning_summary_text.delta` (and `reasoning_text.delta`):
      the reasoning shown live; summary parts are separated by a blank line
    * `response.output_item.added` and `response.function_call_arguments.delta`:
      a tool call as it is written; `response.output_item.done` gives each
      finished item, whose arguments win over the deltas, and the reasoning
      items to hand back next time
    * `response.completed` and `response.incomplete`: the end, with usage
    * `response.failed` and `error`: a failure

  Events of other types, or of an unexpected shape, are skipped.
  """

  use Boundary,
    type: :strict,
    deps: [PhotonCore, PhotonCore.LLM.Error, PhotonCore.LLM.HTTPError, PhotonCore.LLM.SSE, Jason]

  alias PhotonCore.LLM.{Error, HTTPError, SSE}
  alias PhotonCore.Message

  defstruct buffer: "",
            text: [],
            reasoning: [],
            calls: %{},
            order: [],
            reasoning_items: [],
            usage: nil,
            model: nil,
            ending: nil,
            error: nil,
            events: []

  @typedoc "A streamed answer as far as it has arrived."
  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Reads the next chunk of the body: returns the answer so far and the events
  the chunk produced, in order.
  """
  @spec feed(t(), String.t()) :: {t(), [tuple()]}
  def feed(%__MODULE__{} = stream, chunk) do
    {payloads, buffer} = SSE.parse(stream.buffer, chunk)

    stream =
      Enum.reduce(payloads, %{stream | buffer: buffer}, fn payload, stream ->
        if ended?(stream), do: stream, else: read(stream, Jason.decode(payload))
      end)

    {%{stream | events: []}, Enum.reverse(stream.events)}
  end

  defp ended?(stream), do: stream.ending != nil or stream.error != nil

  defp read(stream, {:ok, %{"type" => type} = event}), do: on(stream, type, event)
  defp read(stream, _other), do: stream

  defp on(stream, "response.output_text.delta", %{"delta" => delta}) when is_binary(delta),
    do: stream |> Map.update!(:text, &[&1, delta]) |> emit({:text, delta})

  defp on(stream, "response.reasoning_summary_text.delta", %{"delta" => delta})
       when is_binary(delta),
       do: reasoning_delta(stream, delta)

  defp on(stream, "response.reasoning_text.delta", %{"delta" => delta}) when is_binary(delta),
    do: reasoning_delta(stream, delta)

  # A new summary part after the first starts a new paragraph.
  defp on(stream, "response.reasoning_summary_part.added", _event)
       when stream.reasoning != [],
       do: reasoning_delta(stream, "\n\n")

  defp on(stream, "response.output_item.added", %{
         "item" => %{"type" => "function_call"} = item,
         "output_index" => output_index
       }),
       do: start_call(stream, output_index, item)

  defp on(stream, "response.function_call_arguments.delta", %{
         "output_index" => output_index,
         "delta" => delta
       })
       when is_binary(delta),
       do: add_arguments(stream, output_index, delta)

  defp on(stream, "response.output_item.done", %{"item" => item, "output_index" => index}),
    do: finish_item(stream, index, item)

  defp on(stream, "response.completed", %{"response" => response}),
    do: ended(stream, :completed, response)

  defp on(stream, "response.incomplete", %{"response" => response}),
    do: ended(stream, :incomplete, response)

  defp on(stream, "response.failed", %{"response" => response}),
    do: %{stream | error: response["error"] || %{"message" => "the response failed"}}

  defp on(stream, "error", event), do: %{stream | error: event["error"] || event}
  defp on(stream, _type, _event), do: stream

  defp reasoning_delta(stream, delta),
    do: stream |> Map.update!(:reasoning, &[&1, delta]) |> emit({:reasoning, delta})

  defp start_call(stream, output_index, item) do
    if Map.has_key?(stream.calls, output_index) do
      stream
    else
      index = length(stream.order)
      {namespace, name} = qualified(item)

      call = %{
        index: index,
        id: item["call_id"],
        name: name,
        namespace: namespace,
        arguments: [item["arguments"] || ""]
      }

      %{
        stream
        | calls: Map.put(stream.calls, output_index, call),
          order: [output_index | stream.order]
      }
      |> emit({:tool_call, index, name, item["arguments"] || ""})
    end
  end

  defp add_arguments(stream, output_index, delta) do
    case stream.calls[output_index] do
      nil ->
        stream

      call ->
        call = %{call | arguments: [call.arguments, delta]}

        %{stream | calls: Map.put(stream.calls, output_index, call)}
        |> emit({:tool_call, call.index, nil, delta})
    end
  end

  # A call's namespace, and its name within it: given apart, or as one
  # qualified name ("functions.Bash").
  defp qualified(%{"namespace" => namespace, "name" => name}) when is_binary(namespace),
    do: {namespace, name}

  defp qualified(%{"name" => "functions." <> name}), do: {"functions", name}
  defp qualified(item), do: {nil, item["name"]}

  defp finish_item(stream, output_index, %{"type" => "function_call"} = item) do
    stream = start_call(stream, output_index, item)
    call = stream.calls[output_index]
    {namespace, name} = qualified(item)

    call = %{
      call
      | id: item["call_id"] || call.id,
        name: name || call.name,
        namespace: namespace || call.namespace,
        arguments: if(is_binary(item["arguments"]), do: [item["arguments"]], else: call.arguments)
    }

    %{stream | calls: Map.put(stream.calls, output_index, call)}
  end

  defp finish_item(stream, _output_index, %{"type" => "reasoning"} = item),
    do: %{stream | reasoning_items: [item | stream.reasoning_items]}

  defp finish_item(stream, _output_index, _item), do: stream

  defp ended(stream, how, response) do
    %{
      stream
      | ending: {how, response["incomplete_details"]},
        usage: response["usage"],
        model: response["model"]
    }
  end

  defp emit(stream, event), do: %{stream | events: [event | stream.events]}

  @doc """
  The result once the body has ended. `call_id` names a tool call the model
  left unnamed (it is given the call's index), so the impure part of naming
  stays with the caller.
  """
  @spec finish(t(), (non_neg_integer() -> String.t())) :: {:ok, map()} | {:error, Error.t()}
  def finish(%__MODULE__{error: error}, _call_id) when error != nil,
    do: {:error, stream_error(error)}

  def finish(%__MODULE__{ending: nil}, _call_id) do
    {:error, Error.new(:stream, "the response stream ended without an answer", retryable: true)}
  end

  def finish(%__MODULE__{} = stream, call_id) do
    message = %{
      "role" => "assistant",
      "content" => Message.parts(IO.iodata_to_binary(stream.text)),
      "reasoning" => blank_to_nil(IO.iodata_to_binary(stream.reasoning)),
      "tool_calls" => tool_calls(stream, call_id),
      "reasoning_items" => Enum.reverse(stream.reasoning_items)
    }

    {:ok,
     %{
       "message" => message,
       "stop" => stop_reason(stream.ending, message["tool_calls"]),
       "usage" => usage(stream.usage),
       "model" => stream.model
     }}
  end

  defp tool_calls(stream, call_id) do
    stream.order
    |> Enum.reverse()
    |> Enum.map(&stream.calls[&1])
    |> Enum.map(fn call ->
      %{
        "id" => call.id || call_id.(call.index),
        "name" => call.name,
        "arguments" => IO.iodata_to_binary(call.arguments)
      }
      |> with_namespace(call.namespace)
    end)
  end

  # The namespace a call was made in, kept so it can be handed back.
  defp with_namespace(call, namespace) when is_binary(namespace),
    do: Map.put(call, "namespace", namespace)

  defp with_namespace(call, _namespace), do: call

  defp stop_reason(_ending, [_ | _]), do: "tool_use"
  defp stop_reason({:incomplete, %{"reason" => "max_output_tokens"}}, _calls), do: "max_tokens"
  defp stop_reason({:incomplete, %{"reason" => "content_filter"}}, _calls), do: "refused"
  defp stop_reason(_ending, _calls), do: "end_turn"

  @doc "Token counts from a Responses `usage` object; missing counts are 0."
  @spec usage(map() | nil) :: %{String.t() => non_neg_integer()}
  def usage(usage) do
    usage = usage || %{}

    %{
      "input" => count(usage["input_tokens"]),
      "cached" => count(details(usage["input_tokens_details"])["cached_tokens"]),
      "output" => count(usage["output_tokens"]),
      "reasoning" => count(details(usage["output_tokens_details"])["reasoning_tokens"])
    }
  end

  defp details(%{} = details), do: details
  defp details(_details), do: %{}

  defp count(n) when is_integer(n) and n >= 0, do: n
  defp count(_n), do: 0

  # Server trouble and rate limits mid-stream may pass on another attempt;
  # anything else (a bad request, a spent plan) won't.
  defp stream_error(error) when is_map(error) do
    code = error["code"]
    message = HTTPError.explain(code) || error["message"] || Jason.encode!(error)
    retryable = code in ["server_error", "rate_limit_exceeded", "server_is_overloaded"]
    Error.new(:stream, message, retryable: retryable)
  end

  defp stream_error(error), do: Error.new(:stream, inspect(error), retryable: false)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text
end
