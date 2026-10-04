defmodule PhotonCredo.Check.CaptureTestLogs do
  use Credo.Check,
    id: "PH0017",
    base_priority: :normal,
    category: :warning,
    explanations: [
      check: """
      Capture logs so test output stays quiet, and assert on a log line when
      it matters (Designing Elixir Systems with OTP, rule 56 in
      docs/otp-design-guide.md). Noise hides failures.

      This check looks at `test_helper.exs` files that start ExUnit:
      `ExUnit.start/1` or `ExUnit.configure/1` must set `capture_log: true`.
      A failing test then still shows its own logs.
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{filename: filename} = source_file, params) do
    {starts?, captures?} = scan(source_file)

    if Path.basename(filename) == "test_helper.exs" and starts? and not captures? do
      [
        format_issue(IssueMeta.for(source_file, params),
          message:
            "The test helper doesn't capture logs: pass capture_log: true to ExUnit.start/1.",
          trigger: "ExUnit",
          line_no: 1
        )
      ]
    else
      []
    end
  end

  # Whether the file starts ExUnit, and whether it sets capture_log: true.
  defp scan(source_file) do
    {_ast, found} =
      Macro.prewalk(SourceFile.ast(source_file), {false, false}, fn
        {{:., _, [{:__aliases__, _, [:ExUnit]}, fun]}, _, args} = node, {starts?, captures?}
        when fun in [:start, :configure] ->
          {node, {starts? or fun == :start, captures? or capture_log?(args)}}

        node, found ->
          {node, found}
      end)

    found
  end

  defp capture_log?([opts]) when is_list(opts), do: Keyword.get(opts, :capture_log) == true
  defp capture_log?(_args), do: false
end
