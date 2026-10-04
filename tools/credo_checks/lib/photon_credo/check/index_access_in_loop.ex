defmodule PhotonCredo.Check.IndexAccessInLoop do
  use Credo.Check,
    id: "PH0014",
    base_priority: :normal,
    category: :refactor,
    explanations: [
      check: """
      Read lists from the head and build them by prepending; avoid index
      access (Designing Elixir Systems with OTP, rule 21 in
      docs/otp-design-guide.md). Reaching the nth element walks the list, so
      doing it once per element of a loop is quadratic.

      This check flags `Enum.at`, `Enum.fetch`, `Enum.fetch!` and
      `:lists.nth` inside the function given to an `Enum` or `Stream`
      function, or inside a `for` comprehension. Walk the lists together
      (`Enum.zip/2`, `Enum.with_index/1`) or use a map or tuple for random
      access. (Appending, `list ++ [item]`, is Credo's
      `Refactor.AppendSingleItem`.)
      """
    ]

  alias PhotonCredo.Ast

  @index_calls [{"Enum", :at}, {"Enum", :fetch}, {"Enum", :fetch!}, {":lists", :nth}]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    source_file
    |> SourceFile.ast()
    |> Ast.modules()
    |> Enum.flat_map(fn info ->
      info.body
      |> loop_bodies(info)
      |> Enum.flat_map(&Ast.remote_calls(&1, info))
      |> Enum.filter(&({&1.module, &1.function} in @index_calls))
      |> Enum.uniq_by(&{&1.line, &1.function})
      |> Enum.map(&issue(issue_meta, &1))
    end)
  end

  # Function arguments given to Enum/Stream calls, and `for` bodies.
  defp loop_bodies(body, info) do
    {_ast, bodies} = Macro.prewalk(body, [], &collect_loop(&1, &2, info))
    bodies
  end

  defp collect_loop({:for, _meta, args} = node, acc, _info) when is_list(args),
    do: {node, [List.last(args) | acc]}

  defp collect_loop({{:., _, [mod, _fun]}, _meta, args} = node, acc, info) when is_list(args) do
    if Ast.resolve(mod, info) in ["Enum", "Stream"],
      do: {node, Enum.filter(args, &function_arg?/1) ++ acc},
      else: {node, acc}
  end

  defp collect_loop(node, acc, _info), do: {node, acc}

  defp function_arg?({:fn, _, _}), do: true
  defp function_arg?({:&, _, _}), do: true
  defp function_arg?(_arg), do: false

  defp issue(issue_meta, call) do
    format_issue(issue_meta,
      message:
        "#{call.module}.#{call.function} inside a loop walks the list once per element. " <>
          "Walk the lists together (Enum.zip/2, Enum.with_index/1) or use a map.",
      trigger: Atom.to_string(call.function),
      line_no: call.line
    )
  end
end
