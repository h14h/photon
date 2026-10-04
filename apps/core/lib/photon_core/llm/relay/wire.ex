defmodule PhotonCore.LLM.Relay.Wire do
  @moduledoc """
  The relay's stream format, as pure functions. The hub runs a node's model
  request itself and streams back what `PhotonCore.LLM.stream/3` reports,
  one server-sent event per item, each a JSON object with a `"type"`:

    * `"text"`, `"reasoning"`: `"delta"`
    * `"tool_call"`: `"index"`, `"name"` (or null) and `"delta"`
    * `"web_search"`: `"id"` and `"action"` (or null)
    * `"retry"`: `"attempt"`, `"delay_ms"` and `"error"`; deltas start over
    * `"done"`: `"response"`, the finished response; the stream ends
    * `"error"`: `"error"`; the stream ends

  An error is `%{"kind", "status", "message", "retryable", "retry_after"}`.
  Comment lines (`": keep-alive"`) keep an idle connection open and carry
  nothing.

  The hub side renders with `event/1`, `done/1`, `error/1` and
  `keep_alive/0`. The node side folds the body with `new/0`, `feed/2` and
  `finish/1`, which doesn't depend on how the body was cut into chunks.
  """

  use Boundary, type: :strict, deps: [PhotonCore.LLM.Error, PhotonCore.LLM.SSE, Jason]

  alias PhotonCore.LLM.{Error, SSE}

  defstruct buffer: "", result: nil

  @typedoc "A relayed stream as far as it has arrived."
  @type t :: %__MODULE__{
          buffer: String.t(),
          result: {:ok, map()} | {:error, Error.t()} | nil
        }

  @kinds %{"http" => :http, "transport" => :transport, "stream" => :stream, "config" => :config}

  ## The hub's side

  @doc "One streamed model event as an SSE event."
  @spec event(tuple()) :: iolist()
  def event({:text, delta}), do: sse(%{"type" => "text", "delta" => delta})
  def event({:reasoning, delta}), do: sse(%{"type" => "reasoning", "delta" => delta})

  def event({:tool_call, index, name, delta}),
    do: sse(%{"type" => "tool_call", "index" => index, "name" => name, "delta" => delta})

  def event({:web_search, id, action}),
    do: sse(%{"type" => "web_search", "id" => id, "action" => action})

  def event({:retry, attempt, delay_ms, %Error{} = error}) do
    sse(%{
      "type" => "retry",
      "attempt" => attempt,
      "delay_ms" => delay_ms,
      "error" => encode_error(error)
    })
  end

  @doc "The finished response, which ends the stream."
  @spec done(map()) :: iolist()
  def done(response), do: sse(%{"type" => "done", "response" => response})

  @doc "The failure that ends the stream."
  @spec error(Error.t()) :: iolist()
  def error(%Error{} = error), do: sse(%{"type" => "error", "error" => encode_error(error)})

  @doc "A comment that keeps the connection open while nothing else comes."
  @spec keep_alive() :: String.t()
  def keep_alive, do: ": keep-alive\n\n"

  @doc "An error as the stream carries it."
  @spec encode_error(Error.t()) :: map()
  def encode_error(%Error{} = error) do
    %{
      "kind" => Atom.to_string(error.kind),
      "status" => error.status,
      "message" => error.message,
      "retryable" => error.retryable,
      "retry_after" => error.retry_after
    }
  end

  defp sse(payload), do: ["data: ", Jason.encode_to_iodata!(payload), "\n\n"]

  ## The node's side

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Reads the next chunk of the body: returns the stream so far and the
  events to report, in order. After `"done"` or `"error"` the rest is
  ignored.
  """
  @spec feed(t(), String.t()) :: {t(), [tuple()]}
  def feed(%__MODULE__{result: result} = stream, _chunk) when result != nil, do: {stream, []}

  def feed(%__MODULE__{} = stream, chunk) do
    {payloads, buffer} = SSE.parse(stream.buffer, chunk)

    {stream, events} =
      Enum.reduce(payloads, {%{stream | buffer: buffer}, []}, fn payload, {stream, events} ->
        read(stream, events, Jason.decode(payload))
      end)

    {stream, Enum.reverse(events)}
  end

  defp read(%{result: result} = stream, events, _payload) when result != nil, do: {stream, events}

  defp read(stream, events, {:ok, %{"type" => "done", "response" => response}})
       when is_map(response),
       do: {%{stream | result: {:ok, response}}, events}

  defp read(stream, events, {:ok, %{"type" => "error", "error" => error}}),
    do: {%{stream | result: {:error, decode_error(error)}}, events}

  defp read(stream, events, {:ok, payload}) do
    case decode_event(payload) do
      nil -> {stream, events}
      event -> {stream, [event | events]}
    end
  end

  defp read(stream, events, {:error, _not_json}), do: {stream, events}

  defp decode_event(%{"type" => "text", "delta" => delta}) when is_binary(delta),
    do: {:text, delta}

  defp decode_event(%{"type" => "reasoning", "delta" => delta}) when is_binary(delta),
    do: {:reasoning, delta}

  defp decode_event(%{"type" => "tool_call", "index" => index, "delta" => delta} = event)
       when is_integer(index) and index >= 0 and is_binary(delta) do
    name = if is_binary(event["name"]), do: event["name"]
    {:tool_call, index, name, delta}
  end

  defp decode_event(%{"type" => "retry", "attempt" => attempt, "delay_ms" => delay} = event)
       when is_integer(attempt) and attempt > 0 and is_integer(delay) and delay >= 0,
       do: {:retry, attempt, delay, decode_error(event["error"])}

  defp decode_event(%{"type" => "web_search", "id" => id} = event) when is_binary(id),
    do: {:web_search, id, event["action"]}

  defp decode_event(_payload), do: nil

  @doc """
  An error from the stream. It already had the hub's retries, so it isn't
  retryable here, whatever it says; its kind, status and message are kept.
  """
  @spec decode_error(term()) :: Error.t()
  def decode_error(%{"message" => message} = error) when is_binary(message) do
    Error.new(Map.get(@kinds, error["kind"], :stream), message,
      status: integer_or_nil(error["status"]),
      retryable: false,
      retry_after: integer_or_nil(error["retry_after"])
    )
  end

  def decode_error(_error), do: Error.new(:stream, "the hub sent an error without a message")

  defp integer_or_nil(value) when is_integer(value) and value >= 0, do: value
  defp integer_or_nil(_value), do: nil

  @doc """
  The result once the body has ended: the response or error the stream
  carried, or a retryable error if it ended before either (the connection
  dropped).
  """
  @spec finish(t()) :: {:ok, map()} | {:error, Error.t()}
  def finish(%__MODULE__{result: nil}),
    do: {:error, Error.new(:stream, "the hub's stream ended without an answer", retryable: true)}

  def finish(%__MODULE__{result: result}), do: result
end
