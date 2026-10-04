defmodule PhotonCredo.Check.SuppressionNeedsReason do
  use Credo.Check,
    id: "PH0020",
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Turning a check off in place is an exception to a rule, so it says why,
      in a comment on the line directly above:

          # The module name is the protocol's, so it can't be shorter.
          # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength

          # The default clause only runs for a corrupt record; see recover/1.
          @dialyzer {:nowarn_function, recover: 1}

      This covers every `credo:disable-for-*` comment and every `@dialyzer`
      attribute. Without a reason, an exception reads like a way to make a
      tool quiet; with one, a reviewer can check it still holds.
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    # String and sigil contents are blanked, so example code in docs and
    # test fixtures isn't mistaken for the real thing.
    lines =
      source_file
      |> Credo.Code.clean_charlists_strings_and_sigils()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.map(fn {text, number} -> {number, text} end)

    by_number = Map.new(lines)

    for {number, text} <- lines,
        kind = suppression(text),
        kind != nil,
        not reason_above?(by_number, number - 1) do
      format_issue(issue_meta,
        message: "Say why, in a comment directly above this #{kind}.",
        trigger: String.trim(text),
        line_no: number
      )
    end
  end

  defp suppression(text) do
    trimmed = String.trim(text)

    cond do
      Regex.match?(~r/^#.*credo:disable-for-/, trimmed) -> "credo:disable comment"
      Regex.match?(~r/^@dialyzer\b/, trimmed) -> "@dialyzer attribute"
      true -> nil
    end
  end

  defp reason_above?(_lines, 0), do: false

  defp reason_above?(lines, number) do
    text = lines |> Map.get(number, "") |> String.trim()
    String.starts_with?(text, "#") and not String.contains?(text, "credo:")
  end
end
