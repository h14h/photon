defmodule Photon.Skills.SkillMd do
  @moduledoc """
  Reads a SKILL.md (section 2.3 of
  `docs/plans/step-3-skills-and-schedules.md`): YAML front matter between a
  first line `---` and the next line `---`, then the instructions.

  The project has no YAML library, so this reads the subset SKILL.md files
  use:

    * a leading byte order mark and `\\r\\n` line ends
    * top-level `key: value` lines, where the key is everything before the
      first `:`
    * plain values, with indented continuation lines folded into one line
      and a ` #` comment dropped; single-quoted values (`''` is a quote);
      double-quoted values (`\\"`, `\\\\`, `\\n`, `\\t` and other escapes);
      and block scalars `|`, `|-`, `>` and `>-` with their indented lines
    * a key whose value is a nested block (`metadata:` followed by
      indented lines, or a list) is skipped as a whole
    * comments (`# ...` on their own line)

  Values are trimmed, so a block scalar's chomping indicator changes
  nothing here.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: []

  @typedoc """
  A parsed SKILL.md. `name` and `description` are nil when missing or
  empty, which install shows as a field to fill in. `ignored` lists the
  other top-level front matter keys, in order.
  """
  @type parsed :: %{
          name: String.t() | nil,
          description: String.t() | nil,
          instructions: String.t(),
          ignored: [String.t()]
        }

  @no_front_matter "A SKILL.md starts with front matter: a line `---`, then `name:` and " <>
                     "`description:`, then `---`."
  @unclosed "The front matter never ends: add a line `---` after it."
  @no_body "This SKILL.md has no instructions after its front matter."

  @doc "Parses a SKILL.md's text; see the moduledoc for what it reads."
  @spec parse(String.t()) :: {:ok, parsed()} | {:error, String.t()}
  def parse(text) do
    lines =
      text
      |> String.trim_leading("﻿")
      |> String.replace("\r\n", "\n")
      |> String.split("\n")

    with {:ok, front, body} <- split(lines),
         {:ok, instructions} <- instructions(body) do
      fields = fields(front, [])

      {:ok,
       %{
         name: value(fields, "name"),
         description: value(fields, "description"),
         instructions: instructions,
         ignored: fields |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.reject(&known?/1)
       }}
    end
  end

  defp known?(key), do: key in ["name", "description"]

  defp split([first | rest]) do
    if delimiter?(first) do
      case Enum.split_while(rest, &(not delimiter?(&1))) do
        {front, [_closing | body]} -> {:ok, front, body}
        {_front, []} -> {:error, @unclosed}
      end
    else
      {:error, @no_front_matter}
    end
  end

  defp delimiter?(line), do: String.trim_trailing(line) == "---"

  defp instructions(body) do
    case body |> Enum.join("\n") |> String.trim() do
      "" -> {:error, @no_body}
      instructions -> {:ok, instructions}
    end
  end

  # The last value of `key`, or nil.
  defp value(fields, key) do
    case fields |> Enum.filter(&(elem(&1, 0) == key)) |> List.last() do
      {_key, value} when is_binary(value) and value != "" -> value
      _missing_nested_or_empty -> nil
    end
  end

  ## Front matter

  # The top-level keys in order, each with its trimmed value, or `:nested`
  # for a block that was skipped.
  defp fields([], fields), do: Enum.reverse(fields)

  defp fields([line | rest], fields) do
    with false <- blank?(line) or indented?(line) or comment?(line),
         [key, value] <- String.split(line, ":", parts: 2) do
      {value, rest} = field_value(String.trim(value), rest)
      fields(rest, [{String.trim(key), value} | fields])
    else
      _skipped -> fields(rest, fields)
    end
  end

  defp field_value("", rest) do
    {block, rest} = Enum.split_while(rest, &(blank?(&1) or indented?(&1) or list_item?(&1)))
    if Enum.all?(block, &blank?/1), do: {"", rest}, else: {:nested, rest}
  end

  defp field_value(<<quote, _::binary>> = value, rest) when quote in [?", ?'] do
    {more, rest} = Enum.split_while(rest, &(blank?(&1) or indented?(&1)))
    {more |> fold_into(value) |> quoted() |> String.trim(), rest}
  end

  defp field_value(value, rest) do
    {more, rest} = Enum.split_while(rest, &(blank?(&1) or indented?(&1)))

    case Regex.run(~r/\A([|>])[+-]?\d*[+-]?\s*(?:#.*)?\z/, value) do
      [_, style] ->
        {more |> block(style) |> String.trim(), rest}

      nil ->
        {more
         |> Enum.reject(&comment?(String.trim(&1)))
         |> Enum.map(&uncomment/1)
         |> fold_into(uncomment(value))
         |> String.trim(), rest}
    end
  end

  defp blank?(line), do: String.trim(line) == ""
  defp indented?(line), do: String.starts_with?(line, [" ", "\t"])
  defp comment?(line), do: String.starts_with?(line, "#")
  defp list_item?(line), do: line == "-" or String.starts_with?(line, "- ")

  # A plain value's ` #` comment, dropped.
  defp uncomment(value), do: value |> String.split(~r/\s#/, parts: 2) |> hd()

  # The first line of a flow value and its continuation lines, folded as
  # YAML does: a line break is a space, and a blank line a newline.
  defp fold_into(more, first), do: fold([first | Enum.map(more, &String.trim/1)])

  ## Scalars

  defp quoted(<<?", rest::binary>>), do: double(rest, "")
  defp quoted(<<?', rest::binary>>), do: single(rest, "")

  defp double(<<?\\, char::utf8, rest::binary>>, acc), do: double(rest, acc <> escape(char))
  defp double(<<?", _after::binary>>, acc), do: acc
  defp double(<<char::utf8, rest::binary>>, acc), do: double(rest, <<acc::binary, char::utf8>>)
  # An unclosed quote, or text that isn't UTF-8: keep what was read.
  defp double(_rest, acc), do: acc

  defp escape(?n), do: "\n"
  defp escape(?t), do: "\t"
  defp escape(?r), do: "\r"
  defp escape(?0), do: <<0>>
  defp escape(char), do: <<char::utf8>>

  defp single(<<?', ?', rest::binary>>, acc), do: single(rest, acc <> "'")
  defp single(<<?', _after::binary>>, acc), do: acc
  defp single(<<char::utf8, rest::binary>>, acc), do: single(rest, <<acc::binary, char::utf8>>)
  defp single(_rest, acc), do: acc

  # A block scalar's lines, without their common indentation: kept as
  # lines for `|`, folded for `>`.
  defp block(lines, style) do
    indent =
      lines
      |> Enum.reject(&blank?/1)
      |> Enum.map(&(byte_size(&1) - byte_size(String.trim_leading(&1))))
      |> Enum.min(fn -> 0 end)

    lines = Enum.map(lines, &unindent(&1, indent))

    case style do
      "|" -> Enum.join(lines, "\n")
      ">" -> fold(lines)
    end
  end

  defp unindent(line, indent) do
    if blank?(line), do: "", else: binary_part(line, indent, byte_size(line) - indent)
  end

  # Folded lines: lines in a paragraph joined by spaces, a blank line a
  # newline, and more-indented lines kept as they are.
  defp fold(lines) do
    lines
    |> Enum.chunk_by(&(&1 == ""))
    |> Enum.map_join(fn
      ["" | _] = blanks ->
        String.duplicate("\n", length(blanks))

      paragraph ->
        Enum.join(paragraph, if(Enum.any?(paragraph, &indented?/1), do: "\n", else: " "))
    end)
  end
end
