defmodule PhotonCore.LLM.SSE do
  @moduledoc """
  Incremental server-sent events parsing. Feed chunks as they arrive; get
  back the `data` payloads of every complete event plus the leftover buffer.

  Lines end with CRLF, LF or a bare CR, as in the WHATWG spec, and an event
  ends at a blank line. The leftover buffer is already normalized to LF,
  except for a CR at its very end, which may be the first half of a CRLF
  split across chunks. So what `parse/2` yields doesn't depend on how the
  stream was cut.

  Pure: the caller keeps the buffer between chunks.
  """

  use Boundary, type: :strict, deps: []

  @doc "Returns `{[data], rest}` for `buffer <> chunk`."
  @spec parse(String.t(), String.t()) :: {[String.t()], String.t()}
  def parse(buffer, chunk) do
    {text, held} = hold_back_trailing_cr(buffer <> chunk)

    {complete, [rest]} =
      text |> normalize_line_endings() |> String.split("\n\n") |> Enum.split(-1)

    {Enum.flat_map(complete, &event_data/1), rest <> held}
  end

  # A CR at the very end may be the first half of a CRLF; it waits for the
  # next chunk.
  defp hold_back_trailing_cr(text)
       when byte_size(text) > 0 and binary_part(text, byte_size(text) - 1, 1) == "\r",
       do: {binary_part(text, 0, byte_size(text) - 1), "\r"}

  defp hold_back_trailing_cr(text), do: {text, ""}

  defp normalize_line_endings(text),
    do: text |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")

  # An event's data is its `data` lines joined with newlines; events with
  # none (comments, keep-alives) produce nothing.
  defp event_data(event) do
    event
    |> String.split("\n")
    |> Enum.flat_map(&data_line/1)
    |> join_data()
  end

  defp join_data([]), do: []
  defp join_data(lines), do: [Enum.join(lines, "\n")]

  # One space after the colon is dropped; other fields are ignored.
  defp data_line("data:" <> value), do: [strip_space(value)]
  defp data_line("data"), do: [""]
  defp data_line(_line), do: []

  defp strip_space(" " <> value), do: value
  defp strip_space(value), do: value
end
