defmodule PhotonNode.Harness.Output do
  @moduledoc """
  Caps on what a tool result shows the model. Limits count Unicode code
  points. Text over the limit keeps its head and tail around a marker that
  says how many bytes were skipped and, when there is one, where the complete
  output is.

  Pure. `PhotonNode.Harness.Ops.Shell` reads only the two ends of a large
  output file and joins them with `truncated/5`.
  """

  # Functional core (see PhotonNode.Harness): no processes, no I/O.
  use Boundary, type: :strict, deps: []

  @default 40_000
  @max 1_000_000

  @spec default_limit() :: pos_integer()
  def default_limit, do: @default

  @spec max_limit() :: pos_integer()
  def max_limit, do: @max

  @doc "Bounds `text` to `limit` code points; returns `{text, truncated?}`."
  @spec bound(binary(), non_neg_integer(), String.t() | nil) :: {String.t(), boolean()}
  def bound(text, limit, path \\ nil) do
    text = sanitize(text)

    if length(String.to_charlist(text)) <= limit,
      do: {text, false},
      else: {truncated(text, text, byte_size(text), limit, path), true}
  end

  @doc "Bounds text and returns only the text."
  @spec bound!(binary(), non_neg_integer(), String.t() | nil) :: String.t()
  def bound!(text, limit, path \\ nil), do: text |> bound(limit, path) |> elem(0)

  @doc """
  The bounded form of an output of `size` bytes that starts with
  `head_text` and ends with `tail_text`: half of `limit` code points from
  the head, the rest from the tail, around a marker with the number of
  bytes left out and `path` (when given).
  """
  @spec truncated(binary(), binary(), non_neg_integer(), non_neg_integer(), String.t() | nil) ::
          String.t()
  def truncated(head_text, tail_text, size, limit, path) do
    head_count = div(limit, 2)
    head = head_text |> sanitize() |> first_codepoints(head_count)
    tail = tail_text |> sanitize() |> last_codepoints(limit - head_count)
    head <> marker(size - byte_size(head) - byte_size(tail), path) <> tail
  end

  @doc "Replaces invalid UTF-8 with U+FFFD."
  @spec sanitize(binary()) :: String.t()
  def sanitize(text) when is_binary(text) do
    if String.valid?(text), do: text, else: String.replace_invalid(text, "�")
  end

  defp first_codepoints(text, count),
    do: text |> String.to_charlist() |> Enum.take(count) |> List.to_string()

  defp last_codepoints(text, count) do
    codepoints = String.to_charlist(text)
    codepoints |> Enum.drop(max(length(codepoints) - count, 0)) |> List.to_string()
  end

  defp marker(skipped, nil), do: "...#{skipped} bytes truncated..."
  defp marker(skipped, path), do: "...#{skipped} bytes truncated; complete output in #{path}..."
end
