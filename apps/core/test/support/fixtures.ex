defmodule PhotonCore.Fixtures do
  @moduledoc """
  Test data builders. Each takes overrides for any field, so a test names
  only what it cares about. Stream chunks are the decoded JSON a provider
  sends; `sse_body/2` turns them into the bytes on the wire.
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  alias PhotonCore.LLM.ChatCompletions.Response
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

  @doc "A config for a custom provider played by the `Req.Test` stub `stub`."
  def stub_config(stub, overrides \\ []) do
    Map.merge(
      %{
        provider: "custom",
        base_url: "http://model.test/v1",
        api_key: "k",
        retry_base_ms: 1,
        req_options: [plug: {Req.Test, stub}]
      },
      Map.new(overrides)
    )
  end

  ## Stream chunks

  @doc "A chunk whose one choice carries `delta`."
  def delta_chunk(delta, overrides \\ []) do
    Map.merge(%{"choices" => [%{"index" => 0, "delta" => delta}]}, Map.new(overrides))
  end

  def text_chunk(text), do: delta_chunk(%{"content" => text})

  def reasoning_chunk(text), do: delta_chunk(%{"reasoning_content" => text})

  @doc """
  A chunk with one tool-call delta. The first delta of a call usually has
  `"id"` and `"function" => %{"name" => ..., "arguments" => ...}`; later
  ones only add arguments.
  """
  def tool_call_chunk(fields), do: delta_chunk(%{"tool_calls" => [Map.new(fields)]})

  @doc "The last chunk of an answer: an empty delta with `reason`."
  def finish_chunk(reason, overrides \\ []) do
    Map.merge(
      %{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => reason}]},
      Map.new(overrides)
    )
  end

  def usage_chunk(prompt_tokens, completion_tokens) do
    %{
      "choices" => [],
      "usage" => %{"prompt_tokens" => prompt_tokens, "completion_tokens" => completion_tokens}
    }
  end

  @doc """
  An SSE body: each chunk as one `data` event, `:done` as `[DONE]`.
  `crlf: true` ends lines with CRLF.
  """
  def sse_body(chunks, opts \\ []) do
    separator = if opts[:crlf], do: "\r\n\r\n", else: "\n\n"

    Enum.map_join(chunks, "", fn
      :done -> "data: [DONE]" <> separator
      chunk -> "data: " <> Jason.encode!(chunk) <> separator
    end)
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
  Folds body pieces through `Response` the way the adapter does and returns
  `{result, events}`: the finished result and every event in order. A call
  the provider left unnamed gets `"call_<index>"`.
  """
  def read_stream(pieces) do
    {response, events} =
      Enum.reduce(pieces, {Response.new(), []}, fn piece, {response, events} ->
        {response, more} = Response.feed(response, piece)
        {response, [more | events]}
      end)

    {Response.finish(response, &"call_#{&1}"), events |> Enum.reverse() |> Enum.concat()}
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
