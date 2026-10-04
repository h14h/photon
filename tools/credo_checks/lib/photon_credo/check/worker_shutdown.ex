defmodule PhotonCredo.Check.WorkerShutdown do
  use Credo.Check,
    id: "PH0009",
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Set shutdown on purpose: a timeout or `:brutal_kill` for workers,
      `:infinity` for supervisors and never for workers (Designing Elixir
      Systems with OTP, rule 85 in docs/otp-design-guide.md). A worker that
      never stops blocks the whole shutdown.

      This check flags `shutdown: :infinity` in a child spec (a keyword list
      or map, `use GenServer` options, `Supervisor.child_spec/2` overrides)
      that doesn't also say `type: :supervisor`.
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    {_ast, {issues, _line}} =
      Macro.prewalk(SourceFile.ast(source_file), {[], 0}, &collect(&1, &2, issue_meta))

    Enum.reverse(issues)
  end

  defp collect({:%{}, meta, pairs} = node, {acc, _line}, issue_meta) when is_list(pairs) do
    line = meta[:line] || 0
    {node, {check_pairs(pairs, line, acc, issue_meta), line}}
  end

  defp collect(list, {acc, line}, issue_meta) when is_list(list),
    do: {list, {check_pairs(list, line, acc, issue_meta), line}}

  defp collect({_form, meta, _args} = node, {acc, line}, _issue_meta) when is_list(meta),
    do: {node, {acc, meta[:line] || line}}

  defp collect(node, acc, _issue_meta), do: {node, acc}

  # `line` is the line of the closest node before the list: keyword lists carry no metadata.
  defp check_pairs(pairs, line, acc, issue_meta) do
    if keyword_like?(pairs) and infinite_worker?(pairs),
      do: [issue(issue_meta, line) | acc],
      else: acc
  end

  defp keyword_like?(pairs), do: Enum.all?(pairs, &match?({key, _} when is_atom(key), &1))

  defp infinite_worker?(pairs),
    do:
      Enum.member?(pairs, {:shutdown, :infinity}) and
        not Enum.member?(pairs, {:type, :supervisor})

  defp issue(issue_meta, line) do
    format_issue(issue_meta,
      message:
        "shutdown: :infinity on a child that isn't a supervisor. Give workers a timeout " <>
          "(or :brutal_kill); only supervisors wait forever.",
      trigger: "shutdown",
      line_no: line
    )
  end
end
