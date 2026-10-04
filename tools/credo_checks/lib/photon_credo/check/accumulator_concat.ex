defmodule PhotonCredo.Check.AccumulatorConcat do
  use Credo.Check,
    id: "PH0013",
    base_priority: :normal,
    category: :refactor,
    explanations: [
      check: """
      Build output as iodata instead of repeated `<>` (Designing Elixir
      Systems with OTP, rule 24 in docs/otp-design-guide.md): each
      concatenation copies the accumulated binary.

      This check flags `<>` on the accumulator inside the function given to
      `Enum.reduce`, `Enum.reduce_while`, `List.foldl` or `List.foldr`, and
      inside a `for ... reduce:` comprehension. Collect a list (iodata) and
      convert it once with `IO.iodata_to_binary/1`, or use `Enum.map_join/3`.
      """
    ]

  alias PhotonCredo.Ast

  @folds [
    {"Enum", :reduce},
    {"Enum", :reduce_while},
    {"List", :foldl},
    {"List", :foldr}
  ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    source_file
    |> SourceFile.ast()
    |> Ast.modules()
    |> Enum.flat_map(fn info ->
      info.body
      |> folders(info)
      |> Enum.flat_map(&concat_lines/1)
      |> Enum.uniq()
      |> Enum.map(&issue(issue_meta, &1))
    end)
  end

  # `{accumulator name, body}` for each fold's function and `for ... reduce:` clause.
  defp folders(body, info) do
    {_ast, found} = Macro.prewalk(body, [], &collect_folder(&1, &2, info))
    found
  end

  defp collect_folder({{:., _, [mod, fun]}, _meta, args} = node, acc, info) when is_list(args) do
    if {Ast.resolve(mod, info), fun} in @folds,
      do: {node, fold_functions(args) ++ acc},
      else: {node, acc}
  end

  defp collect_folder({:for, _meta, args} = node, acc, _info) when is_list(args),
    do: {node, reduce_clauses(args) ++ acc}

  defp collect_folder(node, acc, _info), do: {node, acc}

  defp fold_functions(args) do
    for {:fn, _, clauses} <- args, {:->, _, [[_elem, acc_pattern], body]} <- clauses do
      {var_name(acc_pattern), body}
    end
  end

  # `for x <- xs, reduce: acc do ... end` puts `reduce:` and `do:` in separate keyword lists.
  defp reduce_clauses(args) do
    opts = args |> Enum.filter(&(is_list(&1) and Keyword.keyword?(&1))) |> Enum.concat()

    with true <- Keyword.has_key?(opts, :reduce),
         clauses when is_list(clauses) <- Keyword.get(opts, :do) do
      for {:->, _, [[acc_pattern], body]} <- clauses, do: {var_name(acc_pattern), body}
    else
      _ -> []
    end
  end

  defp var_name({name, _meta, context}) when is_atom(name) and is_atom(context), do: name
  defp var_name(_pattern), do: nil

  defp concat_lines({nil, _body}), do: []

  defp concat_lines({acc, body}) do
    {_ast, lines} =
      Macro.prewalk(body, [], fn
        {:<>, meta, operands} = node, lines ->
          if Enum.any?(operands, &match?({^acc, _, context} when is_atom(context), &1)),
            do: {node, [meta[:line] | lines]},
            else: {node, lines}

        node, lines ->
          {node, lines}
      end)

    lines
  end

  defp issue(issue_meta, line) do
    format_issue(issue_meta,
      message:
        "<> on a fold's accumulator copies the whole binary on every step. Collect iodata " <>
          "and convert it once (IO.iodata_to_binary/1), or use Enum.map_join/3.",
      trigger: "<>",
      line_no: line
    )
  end
end
