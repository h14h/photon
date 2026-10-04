defmodule PhotonCredo.Check.DeepAccessPath do
  use Credo.Check,
    id: "PH0011",
    base_priority: :normal,
    category: :refactor,
    param_defaults: [max_depth: 2],
    explanations: [
      check: """
      Prefer flat data to deep nesting, for example a map keyed by
      `{row, col}` instead of tuples of tuples (Designing Elixir Systems with
      OTP, rule 14 in docs/otp-design-guide.md). A deep update rebuilds
      every level above it, and deep data makes pattern matches harder.

      This check flags `get_in`, `put_in`, `update_in`, `pop_in` and
      `get_and_update_in` paths deeper than `max_depth`: a literal key list
      (`get_in(data, [:a, :b, :c])`) or an access path
      (`put_in(state.a.b[:c], value)`). Data whose shape is fixed elsewhere
      (a stored or wire format) can be read where it is, with a
      `credo:disable-for-next-line` comment that says so.
      """,
      params: [max_depth: "The deepest path allowed."]
    ]

  @path_macros [:get_in, :put_in, :update_in, :pop_in, :get_and_update_in]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    max_depth = Params.get(params, :max_depth, __MODULE__)

    {_ast, issues} =
      Macro.prewalk(SourceFile.ast(source_file), [], fn
        {name, meta, [_ | _] = args} = node, acc when name in @path_macros ->
          depth = path_depth(name, args)

          if depth > max_depth,
            do: {node, [issue(issue_meta, name, depth, max_depth, meta[:line]) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  @function_arity %{get_in: 2, put_in: 3, update_in: 3, pop_in: 2, get_and_update_in: 3}

  # The function form takes a key list after the data (or, piped, first);
  # the macro form takes an access path.
  defp path_depth(name, args) do
    full = Map.fetch!(@function_arity, name)

    cond do
      length(args) == full -> list_length(Enum.at(args, 1))
      length(args) == full - 1 and is_list(hd(args)) -> length(hd(args))
      name != :get_in -> access_depth(hd(args))
      true -> 0
    end
  end

  defp list_length(keys) when is_list(keys), do: length(keys)
  defp list_length(_keys), do: 0

  defp access_depth({{:., _, [Access, :get]}, _meta, [inner, _key]}), do: access_depth(inner) + 1

  defp access_depth({{:., _, [inner, field]}, _meta, []}) when is_atom(field),
    do: access_depth(inner) + 1

  defp access_depth(_root), do: 0

  defp issue(issue_meta, name, depth, max_depth, line) do
    format_issue(issue_meta,
      message:
        "#{name} reaches #{depth} levels deep (max #{max_depth}). Flatten the data, or name " <>
          "the intermediate level with a function.",
      trigger: Atom.to_string(name),
      line_no: line
    )
  end
end
