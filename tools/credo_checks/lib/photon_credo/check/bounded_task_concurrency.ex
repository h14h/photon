defmodule PhotonCredo.Check.BoundedTaskConcurrency do
  use Credo.Check,
    id: "PH0007",
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      Bound concurrency: use `Task.async_stream` (or
      `Task.Supervisor.async_stream_nolink`), whose `max_concurrency`
      defaults to the scheduler count, instead of starting a task per element
      (Designing Elixir Systems with OTP, rule 93 in
      docs/otp-design-guide.md). Unbounded tasks remove back pressure and
      can swamp a connection pool.

      This check flags `Task.async`, `Task.start` and the `Task.Supervisor`
      equivalents inside the function given to an `Enum` or `Stream`
      function, or inside a `for` comprehension.
      """
    ]

  alias PhotonCredo.Ast

  @spawning [
    {"Task", :async},
    {"Task", :start},
    {"Task", :start_link},
    {"Task.Supervisor", :async},
    {"Task.Supervisor", :async_nolink},
    {"Task.Supervisor", :start_child}
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
      |> loop_bodies(info)
      |> Enum.flat_map(&Ast.remote_calls(&1, info))
      |> Enum.filter(&({&1.module, &1.function} in @spawning))
      |> Enum.uniq_by(& &1.line)
      |> Enum.map(&issue(issue_meta, &1))
    end)
  end

  # The bodies of `for` comprehensions and of the arguments given to Enum/Stream functions.
  defp loop_bodies(body, info) do
    {_ast, bodies} = Macro.prewalk(body, [], &collect_loop(&1, &2, info))
    bodies
  end

  defp collect_loop({:for, _meta, args} = node, acc, _info) when is_list(args),
    do: {node, [args | acc]}

  defp collect_loop({{:., _, [mod, _fun]}, _meta, args} = node, acc, info) when is_list(args) do
    if Ast.resolve(mod, info) in ["Enum", "Stream"],
      do: {node, [args | acc]},
      else: {node, acc}
  end

  defp collect_loop(node, acc, _info), do: {node, acc}

  defp issue(issue_meta, call) do
    format_issue(issue_meta,
      message:
        "#{call.module}.#{call.function} inside a loop starts one task per element. " <>
          "Use Task.async_stream (bounded by max_concurrency) instead.",
      trigger: Atom.to_string(call.function),
      line_no: call.line
    )
  end
end
