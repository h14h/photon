defmodule PhotonCredo.Check.SupervisedProcesses do
  use Credo.Check,
    id: "PH0006",
    base_priority: :high,
    category: :design,
    param_defaults: [allowed: []],
    explanations: [
      check: """
      Start every long-lived process under a supervisor, through
      `start_link`, and use OTP abstractions rather than naked processes
      (Designing Elixir Systems with OTP, rules 16, 80 and 91 in
      docs/otp-design-guide.md): "Elixir can't manage what it doesn't know
      about."

      This check flags `spawn`, `spawn_link`, `spawn_monitor`,
      `Process.spawn`, `:proc_lib` and `:erlang` spawns, `Task.start`
      (unsupervised fire and forget), `GenServer.start` (unlinked), and
      `Agent`, which wraps data in a process to make it mutable (rule 16).
      Use `Task.Supervisor`, a `DynamicSupervisor`, or a child spec instead,
      or list the module under `allowed` with the reason.
      """,
      params: [
        allowed: "`[{module_pattern, \"reason\"}]`: modules whose bare processes are deliberate."
      ]
    ]

  alias PhotonCredo.Ast

  @local_spawns [:spawn, :spawn_link, :spawn_monitor]

  @remote [
    {"Kernel", :spawn},
    {"Kernel", :spawn_link},
    {"Kernel", :spawn_monitor},
    {"Process", :spawn},
    {":erlang", :spawn},
    {":erlang", :spawn_link},
    {":erlang", :spawn_monitor},
    {":erlang", :spawn_opt},
    {":proc_lib", :spawn},
    {":proc_lib", :spawn_link},
    {":proc_lib", :spawn_opt},
    {"Task", :start},
    {"GenServer", :start},
    {":gen_server", :start}
  ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    allowed = Params.get(params, :allowed, __MODULE__)

    source_file
    |> SourceFile.ast()
    |> Ast.modules()
    |> Enum.reject(&Ast.allowed_with_reason?(&1.name, allowed))
    |> Enum.flat_map(&module_issues(&1, issue_meta))
  end

  defp module_issues(info, issue_meta) do
    remote =
      for call <- Ast.remote_calls(info.body, info),
          {call.module, call.function} in @remote or call.module == "Agent" do
        issue(issue_meta, call.line, "#{call.function}", "#{call.module}.#{call.function}")
      end

    remote ++ agent_uses(info, issue_meta) ++ local_spawns(info.body, issue_meta)
  end

  defp agent_uses(info, issue_meta) do
    case Ast.use_opts(info, ["Agent"]) do
      nil -> []
      _use -> [issue(issue_meta, info.line, "Agent", "use Agent")]
    end
  end

  defp local_spawns(body, issue_meta) do
    {_ast, issues} =
      Macro.prewalk(body, [], fn
        {name, meta, args} = node, acc when name in @local_spawns and length(args) in [1, 3] ->
          {node, [issue(issue_meta, meta[:line], "#{name}", "#{name}/#{length(args)}") | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp issue(issue_meta, line, trigger, what) do
    format_issue(issue_meta,
      message:
        "#{what} starts a process no supervisor knows about. Start it under a supervisor " <>
          "(Task.Supervisor, DynamicSupervisor, a child spec), or allow-list the module.",
      trigger: trigger,
      line_no: line
    )
  end
end
