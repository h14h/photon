defmodule PhotonCredo.Check.ProcessNameOwnership do
  use Credo.Check,
    id: "PH0015",
    base_priority: :high,
    category: :design,
    param_defaults: [
      names: [],
      api_modules: [],
      exposing_functions: [:via, :whereis, :pid, :server, :server_name, :process_name, :registry],
      exposing_types: [
        "pid",
        "GenServer.server",
        "GenServer.name",
        ":gen_server.server_ref",
        "Registry.registry",
        "Supervisor.supervisor"
      ],
      lifecycle_functions: [:start_link, :start, :child_spec, :init]
    ],
    explanations: [
      check: """
      A boundary is a thin API of plain functions in front of its processes
      (Designing Elixir Systems with OTP, rules 62 and 83 in
      docs/otp-design-guide.md). Callers pass IDs and get data back; the
      processes, their names and their pids stay behind the API.

      Two things are flagged:

        * a reference to a registered process name (a registry, a task
          supervisor, a named server) from a module that doesn't own it, as
          listed in `names`
        * a public function of an API module (`api_modules`) that hands out
          a process: named `via`, `whereis`, `pid`, ..., returning a
          `{:via, ...}` tuple, or with a `@spec` that mentions `pid()`,
          `GenServer.server()` and the like. Lifecycle functions
          (`start_link/1`, `child_spec/1`) are exempt.
      """,
      params: [
        names: "`[{process_name, [owner_module_pattern, ...]}]`: who may name each process.",
        api_modules: "Module patterns of boundary API modules.",
        exposing_functions: "Public function names that hand out a process.",
        exposing_types: "Types that stand for a process in a public spec.",
        lifecycle_functions: "Public functions exempt from the API part (they start processes)."
      ]
    ]

  alias PhotonCredo.Ast

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    names = Params.get(params, :names, __MODULE__)
    api_modules = Params.get(params, :api_modules, __MODULE__)

    api_rules = %{
      functions: Params.get(params, :exposing_functions, __MODULE__),
      types: Enum.map(Params.get(params, :exposing_types, __MODULE__), &Ast.normalize/1),
      lifecycle: Params.get(params, :lifecycle_functions, __MODULE__)
    }

    for info <- Ast.modules(SourceFile.ast(source_file)),
        issue <-
          name_issues(info, names, issue_meta) ++
            api_issues(info, api_modules, api_rules, issue_meta),
        do: issue
  end

  ## Process names

  defp name_issues(info, names, issue_meta) do
    foreign =
      for {name, owners} <- names, not Ast.matches?(info.name, owners), into: %{} do
        {Ast.normalize(name), owners}
      end

    if foreign == %{}, do: [], else: foreign_name_issues(info, foreign, issue_meta)
  end

  defp foreign_name_issues(info, foreign, issue_meta) do
    {_ast, issues} =
      Macro.prewalk(info.body, [], fn
        {:__aliases__, meta, _parts} = node, acc ->
          resolved = Ast.resolve(node, info)

          case Map.fetch(foreign, resolved) do
            {:ok, owners} -> {node, [name_issue(issue_meta, info, resolved, owners, meta) | acc]}
            :error -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp name_issue(issue_meta, info, name, owners, meta) do
    format_issue(issue_meta,
      message:
        "#{info.name} names the process #{name}, which belongs to " <>
          "#{Enum.map_join(owners, ", ", &Ast.normalize/1)}. Go through the owner's API instead.",
      trigger: name |> String.split(".") |> List.last(),
      line_no: meta[:line]
    )
  end

  ## API modules

  defp api_issues(info, api_modules, rules, issue_meta) do
    if Ast.matches?(info.name, api_modules) do
      specs = specs(info)

      info
      |> Ast.clauses()
      |> Enum.filter(&(public_api?(&1, rules) and exposes?(&1, specs, info, rules)))
      |> Enum.uniq_by(&{&1.name, &1.arity})
      |> Enum.map(&api_issue(issue_meta, info, &1))
    else
      []
    end
  end

  defp public_api?(clause, rules), do: clause.kind == :def and clause.name not in rules.lifecycle

  defp exposes?(clause, specs, info, rules) do
    clause.name in rules.functions or returns_via?(clause.body) or
      Enum.any?(Map.get(specs, {clause.name, clause.arity}, []), &mentions_type?(&1, info, rules))
  end

  defp returns_via?({:__block__, _, [body | _]}), do: last_expression_via?(body)

  defp last_expression_via?({:__block__, _, [_ | _] = exprs}),
    do: last_expression_via?(List.last(exprs))

  defp last_expression_via?({:{}, _, [:via | _]}), do: true
  defp last_expression_via?(_expr), do: false

  # `%{{name, arity} => [return type ast]}` from the module's @specs.
  defp specs(info) do
    for {:@, _, [{:spec, _, [spec]}]} <- Ast.top_level_forms(info.body),
        {name, arity, returns} <- [spec_parts(spec)],
        reduce: %{} do
      acc -> Map.update(acc, {name, arity}, [returns], &[returns | &1])
    end
  end

  defp spec_parts({:when, _, [spec, _constraints]}), do: spec_parts(spec)

  defp spec_parts({:"::", _, [{name, _, args}, returns]}) when is_atom(name),
    do: {name, length(List.wrap(args)), returns}

  defp spec_parts(_spec), do: {nil, 0, nil}

  defp mentions_type?(returns, info, rules) do
    {_ast, found} =
      Macro.prewalk(returns, false, fn
        {{:., _, [mod, fun]}, _, []} = node, found ->
          {node, found or "#{Ast.resolve(mod, info)}.#{fun}" in rules.types}

        {name, _, []} = node, found when is_atom(name) ->
          {node, found or Atom.to_string(name) in rules.types}

        node, found ->
          {node, found}
      end)

    found
  end

  defp api_issue(issue_meta, info, clause) do
    format_issue(issue_meta,
      message:
        "#{info.name}.#{clause.name}/#{clause.arity} hands out a process (a pid, a name or a " <>
          "via tuple). An API takes IDs and returns data; keep the processes behind it.",
      trigger: Atom.to_string(clause.name),
      line_no: clause.line
    )
  end
end
