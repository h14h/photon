defmodule Photon.Markdown do
  @moduledoc """
  CommonMark with GitHub-flavored tables, autolinks, strikethrough and task lists.

  Treat every message as untrusted: raw HTML is displayed as text and dangerous
  link schemes are blocked by Comrak. Never enable `unsafe` or HEEx rendering
  here, since model output must not become executable HTML or LiveView bindings.

  Text that is still streaming in is shown a block at a time (`settled/1`),
  the way T3 Code does it: a paragraph, list item or code block appears
  once it's finished, rather than word by word.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [MDEx]

  # What ends a block (see settled/1). Fences may be indented, since a fence
  # inside a list item is; a blank line holds only spaces and tabs; a list
  # item needs the space after its marker, so a half-written `-` or `1.`
  # never counts; a section title is a heading or a line of only bold text,
  # which models often use as one; an unindented heading ends the block
  # above it even without a blank line.
  @fence ~r/^( *)(`{3,}|~{3,})/
  @blank ~r/^[ \t]*$/
  @list_item ~r/^[ \t]*(?:[-*+]|\d{1,9}[.)])[ \t]/
  @section_title ~r/^ {0,3}(?:\#{1,6}(?:[ \t]|$)|\*\*(?:[^*]|\*(?!\*))+\*\*:?$)/
  @top_heading ~r/^\#{1,6}(?:[ \t]|$)/

  @doc """
  The part of streaming `text` that's safe to show: everything up to the
  last finished block, which more text can't change the shape of. A block
  ends at a blank line, a closing code fence, the start of a list item, or
  an unindented heading, none of them inside an open code fence; only
  finished lines count, except that a list item may start on the last,
  partial line (tight lists have no blank lines between items). A section
  title holds back until a line of content follows it, so it never sits
  alone above a block still being written.

  A port of T3 Code's `splitBufferedAssistantText`.
  """
  @spec settled(String.t()) :: String.t()
  def settled(text) when is_binary(text) do
    lines = String.split(text, "\n")
    last = length(lines) - 1
    start = %{fence: nil, boundary: 0, offset: 0, title: false}

    %{boundary: boundary} =
      lines
      |> Enum.with_index()
      |> Enum.reduce_while(start, fn {line, index}, acc ->
        trimmed = String.replace(line, ~r/[ \t\r]+$/, "")
        acc = list_item(acc, trimmed)
        # Where the next line starts: the end of this one in `text`.
        ends = acc.offset + byte_size(line) + 1

        if index == last,
          do: {:halt, acc},
          else: {:cont, %{finished(acc, trimmed, ends) | offset: ends}}
      end)

    binary_part(text, 0, boundary)
  end

  # A list item starts a block, even on the last, partial line.
  defp list_item(%{fence: nil, title: false, offset: offset} = acc, line) when offset > 0 do
    if Regex.match?(@list_item, line), do: %{acc | boundary: offset}, else: acc
  end

  defp list_item(acc, _line), do: acc

  # A finished line: fences open and close, blank lines and headings end blocks.
  defp finished(acc, line, ends) do
    case Regex.run(@fence, line) do
      [_all, indent, marker] -> fence(acc, line, byte_size(indent), marker, ends)
      nil -> plain(acc, line, ends)
    end
  end

  defp fence(%{fence: nil} = acc, _line, indent, marker, _ends),
    do: %{acc | fence: {marker, indent}, title: false}

  defp fence(%{fence: {open, open_indent}} = acc, line, indent, marker, ends) do
    # CommonMark: a closing fence repeats the opener's character, at least as
    # many times, no more than three spaces deeper, with no info string.
    closes? =
      binary_part(marker, 0, 1) == binary_part(open, 0, 1) and
        byte_size(marker) >= byte_size(open) and indent <= open_indent + 3 and
        byte_size(line) == indent + byte_size(marker)

    if closes?, do: %{acc | fence: nil, boundary: ends}, else: acc
  end

  defp plain(%{fence: nil, offset: offset} = acc, line, ends) when offset > 0 do
    cond do
      Regex.match?(@blank, line) ->
        if acc.title, do: acc, else: %{acc | boundary: ends}

      not acc.title and Regex.match?(@top_heading, line) ->
        %{acc | boundary: offset, title: Regex.match?(@section_title, line)}

      true ->
        %{acc | title: Regex.match?(@section_title, line)}
    end
  end

  defp plain(%{fence: nil} = acc, line, _ends),
    do: %{acc | title: Regex.match?(@section_title, line)}

  defp plain(acc, _line, _ends), do: acc

  @spec to_html(String.t()) :: String.t()
  def to_html(text) when is_binary(text) do
    MDEx.to_html!(text,
      extension: [table: true, autolink: true, strikethrough: true, tasklist: true],
      render: [unsafe: false, escape: true, tasklist_classes: true],
      syntax_highlight: nil
    )
  end
end
