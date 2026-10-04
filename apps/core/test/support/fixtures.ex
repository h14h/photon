defmodule PhotonCore.Fixtures do
  @moduledoc """
  Test data builders. Each takes overrides for any field, so a test names
  only what it cares about. Stream events are the decoded JSON the
  Responses API sends; `sse_body/2` turns them into the bytes on the wire.
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  alias PhotonCore.LLM.Responses.Response
  alias PhotonCore.LLM.SSE
  alias PhotonCore.Message

  ## Requests and configs

  @doc "A model request; `overrides` replace its fields."
  def request(overrides \\ []) do
    Map.merge(
      %{model: "m", system: "Be brief.", messages: [Message.user("hi")], tools: []},
      Map.new(overrides)
    )
  end

  @doc "A ChatGPT config whose API is played by the `Req.Test` stub `stub`."
  def stub_config(stub, overrides \\ []) do
    Map.merge(
      %{
        provider: "chatgpt",
        base_url: "http://model.test/v1",
        api_key: "k",
        retry_base_ms: 1,
        req_options: [plug: {Req.Test, stub}]
      },
      Map.new(overrides)
    )
  end

  ## Stream events

  def text_delta(text), do: %{"type" => "response.output_text.delta", "delta" => text}

  def reasoning_delta(text),
    do: %{"type" => "response.reasoning_summary_text.delta", "delta" => text}

  def summary_part_added, do: %{"type" => "response.reasoning_summary_part.added"}

  @doc "A tool call starting at `output_index`."
  def call_added(output_index, call_id, name, arguments \\ "") do
    %{
      "type" => "response.output_item.added",
      "output_index" => output_index,
      "item" => %{
        "type" => "function_call",
        "call_id" => call_id,
        "name" => name,
        "arguments" => arguments
      }
    }
  end

  def arguments_delta(output_index, delta) do
    %{
      "type" => "response.function_call_arguments.delta",
      "output_index" => output_index,
      "delta" => delta
    }
  end

  @doc "A finished output item at `output_index`."
  def item_done(output_index, item),
    do: %{"type" => "response.output_item.done", "output_index" => output_index, "item" => item}

  @doc "The end of an answer, with `usage` counts and the model."
  def completed(fields \\ []) do
    fields = Map.new(fields)

    %{
      "type" => "response.completed",
      "response" => %{
        "status" => "completed",
        "model" => Map.get(fields, :model, "m"),
        "usage" => Map.get(fields, :usage)
      }
    }
  end

  @doc "An answer cut short for `reason` (`max_output_tokens`, `content_filter`)."
  def incomplete(reason) do
    %{
      "type" => "response.incomplete",
      "response" => %{"status" => "incomplete", "incomplete_details" => %{"reason" => reason}}
    }
  end

  def failed(code, message) do
    %{
      "type" => "response.failed",
      "response" => %{"status" => "failed", "error" => %{"code" => code, "message" => message}}
    }
  end

  def usage(input, output, cached \\ 0, reasoning \\ 0) do
    %{
      "input_tokens" => input,
      "input_tokens_details" => %{"cached_tokens" => cached},
      "output_tokens" => output,
      "output_tokens_details" => %{"reasoning_tokens" => reasoning}
    }
  end

  @doc "An SSE body: each event as one `data` event. `crlf: true` ends lines with CRLF."
  def sse_body(events, opts \\ []) do
    separator = if opts[:crlf], do: "\r\n\r\n", else: "\n\n"
    Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> separator))
  end

  @doc "Cuts `text` at the given byte offsets (taken modulo its size + 1)."
  def split_at(text, cuts) do
    size = byte_size(text)
    points = cuts |> Enum.map(&rem(&1, size + 1)) |> Enum.uniq() |> Enum.sort()

    {pieces, last} =
      Enum.reduce(points, {[], 0}, fn point, {pieces, from} ->
        {[binary_part(text, from, point - from) | pieces], point}
      end)

    Enum.reverse([binary_part(text, last, size - last) | pieces])
  end

  ## Folding streams the way the adapter does

  @doc "Parses SSE pieces one at a time, as `Response.feed/2` does: `{data, buffer}`."
  def parse_sse(pieces) do
    {data, buffer} =
      Enum.reduce(pieces, {[], ""}, fn piece, {data, buffer} ->
        {more, buffer} = SSE.parse(buffer, piece)
        {[more | data], buffer}
      end)

    {data |> Enum.reverse() |> Enum.concat(), buffer}
  end

  @doc """
  Folds body pieces through `Responses.Response` the way the adapter does and
  returns `{result, events}`: the finished result and every event in order.
  A call the model left unnamed gets `"call_<index>"`.
  """
  def read_stream(pieces) do
    {stream, events} =
      Enum.reduce(pieces, {Response.new(), []}, fn piece, {stream, events} ->
        {stream, more} = Response.feed(stream, piece)
        {stream, [more | events]}
      end)

    {Response.finish(stream, &"call_#{&1}"), events |> Enum.reverse() |> Enum.concat()}
  end

  @doc """
  Runs `fun` with an `on_event` callback and returns `{result, events}`.
  The events are the ones `fun` reported before it returned, in order.
  """
  def capture_events(fun) do
    test_process = self()
    result = fun.(fn event -> send(test_process, {:captured_event, event}) end)
    {result, take_events([])}
  end

  # Everything was sent before `fun` returned, so the mailbox already holds
  # it all; `after 0` only stops at the end.
  defp take_events(events) do
    receive do
      {:captured_event, event} -> take_events([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end
end
