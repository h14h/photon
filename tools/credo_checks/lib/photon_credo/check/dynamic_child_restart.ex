defmodule PhotonCredo.Check.DynamicChildRestart do
  use Credo.Check,
    id: "PH0010",
    base_priority: :normal,
    category: :design,
    run_on_all: true,
    param_defaults: [process_modules: ["GenServer", "Agent", "Task", "Supervisor", "Slipstream"]],
    explanations: [
      check: """
      Give dynamic processes a deliberate child spec: a unique `:id`, the
      `:start` call, and a chosen `:restart` (`:temporary` when a restart
      can't help) (Designing Elixir Systems with OTP, rule 82 in
      docs/otp-design-guide.md). A child spec is a policy, not boilerplate.

      This check looks at every `DynamicSupervisor.start_child/2` call and
      the modules it starts: the child spec passed directly (`{Mod, arg}`,
      `Mod`), or, when the spec is computed, every `{Mod, arg}` tuple in the
      calling module. Each such module defined in the project with
      `use GenServer` (or another process behaviour) must choose `restart:`
      in its `use` options or its `child_spec/1`.
      """,
      params: [process_modules: "Behaviours whose `use` defines a child spec."]
    ]

  alias PhotonCredo.Ast

  @doc false
  @impl true
  def run_on_all_source_files(exec, source_files, params) do
    process_modules = Params.get(params, :process_modules, __MODULE__)
    parsed = Enum.map(source_files, &{&1, Ast.modules(SourceFile.ast(&1))})
    restart_by_module = restart_by_module(parsed, process_modules)

    parsed
    |> Enum.flat_map(fn {source_file, infos} ->
      for info <- infos,
          {line, child} <- started_children(info),
          Map.get(restart_by_module, child) == false,
          do: issue(IssueMeta.for(source_file, params), child, line)
    end)
    |> append_issues_and_timings(exec)

    :ok
  end

  # `%{module => whether it chooses a restart}` for every process module in the project.
  defp restart_by_module(parsed, process_modules) do
    for {_source_file, infos} <- parsed,
        info <- infos,
        Ast.use_opts(info, process_modules) != nil,
        into: %{},
        do: {info.name, declares_restart?(info, process_modules)}
  end

  defp issue(issue_meta, child, line) do
    format_issue(issue_meta,
      message:
        "DynamicSupervisor.start_child starts #{child}, which doesn't choose a restart " <>
          "strategy. Set restart: in its `use` options or child_spec/1 (:temporary, " <>
          ":transient or :permanent).",
      trigger: "start_child",
      line_no: line
    )
  end

  defp declares_restart?(info, process_modules) do
    {_name, opts} = Ast.use_opts(info, process_modules)
    keyword_has_restart?(opts) or child_spec_sets_restart?(info)
  end

  defp keyword_has_restart?(opts) when is_list(opts), do: Keyword.has_key?(opts, :restart)
  defp keyword_has_restart?(_opts), do: false

  defp child_spec_sets_restart?(info) do
    info
    |> Ast.clauses()
    |> Enum.filter(&(&1.name == :child_spec))
    |> Enum.any?(&mentions_restart?(&1.body))
  end

  defp mentions_restart?(ast) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn
        {:restart, _value} = node, _found -> {node, true}
        node, found -> {node, found}
      end)

    found
  end

  # `{line, module}` for each child this module starts under a DynamicSupervisor.
  # A computed child spec stands for every `{Mod, arg}` tuple in the same function.
  defp started_children(info) do
    for clause <- Ast.clauses(info),
        call <- Ast.remote_calls(clause.body, info),
        call.module == "DynamicSupervisor" and call.function == :start_child,
        child <- children(Enum.at(call.args, 1), clause.body, info),
        do: {call.line, child}
  end

  defp children(spec, body, info) do
    case direct_child(spec, info) do
      {:literal, nil} -> []
      {:literal, module} -> [module]
      :computed -> child_tuples(body, info)
    end
  end

  defp direct_child({:%{}, _meta, _pairs}, _info), do: {:literal, nil}

  defp direct_child({{:., _, [_supervisor, :child_spec]}, _meta, [_spec, opts]}, _info)
       when is_list(opts) do
    if Keyword.has_key?(opts, :restart), do: {:literal, nil}, else: :computed
  end

  defp direct_child({child, _arg}, info), do: {:literal, Ast.resolve(child, info)}
  defp direct_child({:__aliases__, _, _} = child, info), do: {:literal, Ast.resolve(child, info)}
  defp direct_child({:__MODULE__, _, _} = child, info), do: {:literal, Ast.resolve(child, info)}
  defp direct_child(_computed, _info), do: :computed

  defp child_tuples(body, info) do
    {_ast, found} =
      Macro.prewalk(body, [], fn
        {{:__aliases__, _, _} = child, _arg} = node, acc ->
          {node, [Ast.resolve(child, info) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(found)
  end
end
