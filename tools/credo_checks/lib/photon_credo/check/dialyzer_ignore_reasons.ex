defmodule PhotonCredo.Check.DialyzerIgnoreReasons do
  use Credo.Check,
    id: "PH0021",
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Every entry in a `.dialyzer_ignore.exs` sits under a comment that says
      why the finding isn't a bug:

          [
            # Integer arithmetic on arguments Dialyzer doesn't take from the
            # spec; the values are milliseconds, integers wherever they're made.
            {"lib/photon/durable/policy.ex", :missing_range},
            {"lib/photon/durable/turn.ex", :missing_range}
          ]

      One comment covers the entries right below it, up to a blank line. The
      file's header comment, above the opening `[`, covers none. Other files
      are ignored by this check.
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{filename: filename} = source_file, params) do
    if Path.basename(filename) == ".dialyzer_ignore.exs" do
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> SourceFile.lines()
      |> unexplained_entries()
      |> Enum.map(fn {number, text} ->
        format_issue(issue_meta,
          message: "Say why this Dialyzer finding is ignored, in a comment above the entry.",
          trigger: String.trim(text),
          line_no: number
        )
      end)
    else
      []
    end
  end

  # Walks the lines: a comment opens a reasoned block, a blank line or the
  # list's bracket closes it, and an entry outside a block is unexplained.
  defp unexplained_entries(lines) do
    {_reasoned, found} =
      Enum.reduce(lines, {false, []}, fn {number, text}, {reasoned, found} ->
        case line_kind(String.trim(text)) do
          :comment -> {true, found}
          :break -> {false, found}
          :entry when reasoned -> {true, found}
          :entry -> {false, [{number, text} | found]}
          :other -> {reasoned, found}
        end
      end)

    Enum.reverse(found)
  end

  defp line_kind(""), do: :break
  defp line_kind("#" <> _), do: :comment
  defp line_kind("[" <> _), do: :break
  defp line_kind("{" <> _), do: :entry
  defp line_kind("~r" <> _), do: :entry
  defp line_kind("\"" <> _), do: :entry
  defp line_kind(_text), do: :other
end
