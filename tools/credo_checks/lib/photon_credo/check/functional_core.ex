defmodule PhotonCredo.Check.FunctionalCore do
  use Credo.Check,
    id: "PH0001",
    base_priority: :high,
    category: :design,
    param_defaults: [
      core_modules: [],
      impure: [
        "GenServer",
        "Agent",
        "Task",
        "Task.Supervisor",
        "Supervisor",
        "DynamicSupervisor",
        "PartitionSupervisor",
        "Registry",
        "Process",
        "Port",
        "Node",
        "File",
        "Logger",
        "Application",
        "Phoenix.PubSub",
        "Req",
        "*.Repo",
        "System.cmd",
        "System.shell",
        "System.get_env",
        "System.fetch_env",
        "System.fetch_env!",
        "System.put_env",
        "System.delete_env",
        "System.find_executable",
        "System.halt",
        "System.stop",
        "System.at_exit",
        "System.tmp_dir",
        "System.tmp_dir!",
        "System.user_home",
        "System.user_home!",
        "IO.puts",
        "IO.write",
        "IO.binwrite",
        "IO.inspect",
        "IO.warn",
        "IO.gets",
        "IO.read",
        "IO.binread",
        "IO.stream",
        "IO.binstream",
        "Code.ensure_loaded",
        "Code.ensure_loaded?",
        "Code.ensure_compiled",
        "Code.ensure_compiled!",
        ":ets",
        ":dets",
        ":persistent_term",
        ":file",
        ":os",
        ":gen_server",
        ":global",
        ":timer",
        ":inet",
        ":erlang.send",
        ":erlang.spawn",
        ":erlang.spawn_link"
      ],
      impure_extra: [],
      nondeterministic: [
        "DateTime.utc_now",
        "DateTime.now",
        "DateTime.now!",
        "NaiveDateTime.utc_now",
        "NaiveDateTime.local_now",
        "Date.utc_today",
        "Time.utc_now",
        "System.system_time",
        "System.monotonic_time",
        "System.os_time",
        "System.unique_integer",
        ":erlang.system_time",
        ":erlang.monotonic_time",
        ":erlang.unique_integer",
        ":erlang.now",
        ":rand",
        ":crypto.strong_rand_bytes",
        "Enum.random",
        "Enum.shuffle",
        "Enum.take_random"
      ],
      nondeterministic_extra: [],
      allowed: []
    ],
    explanations: [
      check: """
      Business logic lives in a functional core: modules of functions with no
      processes, no external services and as few side effects as possible
      (Designing Elixir Systems with OTP, rules 28 and 29 in
      docs/otp-design-guide.md). The process machinery and I/O live in
      boundary modules that call the core.

      In a functional-core module this check flags, inside function bodies:

        * process and I/O primitives: `GenServer`, `Process`, `Task`,
          `send/2`, `receive`, `spawn`, `Port`, `File`, `System.cmd`,
          `Logger`, `Application` env reads, `:ets`, repos (`*.Repo`),
          `Phoenix.PubSub`, `Req`, ...
        * calls whose result isn't repeatable: the clock, randomness and ID
          generators. Take the value as an argument, or allow-list the call
          for the module when the impurity is chosen on purpose.

      Code outside functions (module attributes, read at compile time) is
      not checked.
      """,
      params: [
        core_modules: "Module patterns of the functional core (`\"A.B\"` or `\"A.B.*\"`).",
        impure:
          "Calls that do I/O or touch processes: `\"Mod\"`, `\"Mod.fun\"`, `\"*.Suffix\"`, `\":erl_mod\"`.",
        impure_extra: "More impure calls, added to `impure`.",
        nondeterministic: "Calls whose results aren't repeatable (clock, randomness).",
        nondeterministic_extra: "More nondeterministic calls (an ID generator, say).",
        allowed: "`[{module_pattern, [call, ...]}]`: calls a core module may make anyway."
      ]
    ]

  alias PhotonCredo.Ast

  @local_impure %{
    send: [2],
    spawn: [1, 3],
    spawn_link: [1, 3],
    spawn_monitor: [1, 3],
    self: [0],
    receive: [1]
  }

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    core = Params.get(params, :core_modules, __MODULE__)

    impure =
      Params.get(params, :impure, __MODULE__) ++ Params.get(params, :impure_extra, __MODULE__)

    nondeterministic =
      Params.get(params, :nondeterministic, __MODULE__) ++
        Params.get(params, :nondeterministic_extra, __MODULE__)

    allowed = Params.get(params, :allowed, __MODULE__)

    source_file
    |> SourceFile.ast()
    |> Ast.modules()
    |> Enum.filter(&Ast.matches?(&1.name, core))
    |> Enum.flat_map(fn info ->
      rules = %{
        impure: impure,
        nondeterministic: nondeterministic,
        allowed: Ast.lookup(info.name, allowed) || []
      }

      module_issues(info, rules, issue_meta)
    end)
  end

  defp module_issues(info, rules, issue_meta) do
    clauses = Ast.clauses(info)
    own_send? = Enum.any?(clauses, &(&1.name == :send and &1.arity == 2))

    Enum.flat_map(clauses, fn clause ->
      code = {:__block__, [], [clause.body | clause.args]}

      remote =
        code
        |> Ast.remote_calls(info)
        |> Enum.flat_map(&remote_issue(&1, info, rules, issue_meta))

      remote ++ local_issues(code, info, own_send?, issue_meta)
    end)
  end

  defp remote_issue(call, info, rules, issue_meta) do
    name = "#{call.module}.#{call.function}"

    cond do
      allowed?(call, rules.allowed) ->
        []

      listed?(call, rules.impure) ->
        [issue(issue_meta, info, %{call | function: name}, :impure)]

      listed?(call, rules.nondeterministic) ->
        [issue(issue_meta, info, %{call | function: name}, :nondeterministic)]

      true ->
        []
    end
  end

  defp local_issues(code, info, own_send?, issue_meta) do
    {_ast, issues} =
      Macro.prewalk(code, [], fn
        {name, meta, args} = node, acc when is_atom(name) and is_list(args) ->
          if local_impure?(name, length(args), own_send?) do
            call = %{function: name, arity: length(args), line: meta[:line]}
            {node, [issue(issue_meta, info, call, :impure) | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp local_impure?(:send, 2, true = _module_defines_send), do: false

  defp local_impure?(name, arity, _own_send?),
    do: arity in Map.get(@local_impure, name, [])

  defp allowed?(call, allowed), do: listed?(call, allowed)

  defp listed?(call, entries), do: Enum.any?(entries, &entry_matches?(call, Ast.normalize(&1)))

  defp entry_matches?(call, "*." <> suffix),
    do: call.module == suffix or String.ends_with?(call.module, "." <> suffix)

  defp entry_matches?(call, entry) do
    case split_entry(entry) do
      {module, nil} -> call.module == module
      {module, function} -> call.module == module and Atom.to_string(call.function) == function
    end
  end

  # "Mod.Sub" names a module, "Mod.fun" a function; ":erl" a module, ":erl.fun" a function.
  defp split_entry(":" <> erlang) do
    case String.split(erlang, ".", parts: 2) do
      [module, function] -> {":" <> module, function}
      [module] -> {":" <> module, nil}
    end
  end

  defp split_entry(entry) do
    parts = String.split(entry, ".")
    last = List.last(parts)

    if last =~ ~r/^[a-z_]/,
      do: {parts |> Enum.drop(-1) |> Enum.join("."), last},
      else: {entry, nil}
  end

  defp issue(issue_meta, info, call, kind) do
    format_issue(issue_meta,
      message:
        "Functional core module #{info.name} calls #{call.function}/#{call.arity}, " <>
          advice(kind),
      trigger: trigger(call.function),
      line_no: call.line
    )
  end

  defp advice(:impure),
    do:
      "which touches processes or does I/O. Move it to a boundary module and pass the result in."

  defp advice(:nondeterministic),
    do:
      "whose result isn't repeatable. Take the value as an argument, or allow-list the call on purpose."

  defp trigger(name) when is_atom(name), do: Atom.to_string(name)
  defp trigger(name), do: name |> String.split(".") |> List.last()
end
