defmodule PhotonCredo.Check.PreferCall do
  use Credo.Check,
    id: "PH0003",
    base_priority: :high,
    category: :design,
    param_defaults: [allowed: []],
    explanations: [
      check: """
      Prefer `GenServer.call` to `GenServer.cast` (Designing Elixir Systems
      with OTP, rule 72 in docs/otp-design-guide.md). A caller can only go
      as fast as the server answers, which is back pressure for free; casts
      and bare sends can flood a mailbox.

      This check flags `GenServer.cast`, `GenServer.abcast`, `handle_cast`
      clauses, and `send/2`, `Process.send/3` and `Process.send_after` to any
      process other than `self()`. Notifying many processes, or a send whose
      loss is recovered some other way, is fine when chosen on purpose: list
      the module under `allowed` with the reason.
      """,
      params: [
        allowed: "`[{module_pattern, \"reason\"}]`: modules whose casts and sends are deliberate."
      ]
    ]

  alias PhotonCredo.Ast

  @casts [
    {"GenServer", :cast},
    {"GenServer", :abcast},
    {":gen_server", :cast},
    {":gen_server", :abcast}
  ]

  @sends [
    {"Kernel", :send},
    {"Process", :send},
    {"Process", :send_after},
    {":erlang", :send},
    {":erlang", :send_after},
    {":timer", :send_after},
    {":timer", :send_interval}
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
    clauses = Ast.clauses(info)
    own_send? = Enum.any?(clauses, &(&1.name == :send and &1.arity == 2))

    casts =
      for clause <- clauses, clause.kind == :def, clause.name == :handle_cast do
        issue(issue_meta, clause.line, "handle_cast", "a handle_cast/2 clause")
      end

    remote =
      for call <- Ast.remote_calls(info.body, info),
          issue = remote_issue(call, issue_meta),
          issue != nil,
          do: issue

    casts ++ remote ++ local_sends(info.body, own_send?, issue_meta)
  end

  defp remote_issue(call, issue_meta) do
    key = {call.module, call.function}

    cond do
      key in @casts ->
        issue(issue_meta, call.line, "#{call.function}", "#{call.module}.#{call.function}")

      key in @sends and not to_self?(destination(call)) ->
        issue(issue_meta, call.line, "#{call.function}", "#{call.module}.#{call.function}")

      true ->
        nil
    end
  end

  # The destination is the first argument, except for `:timer`, where it's the second.
  defp destination(%{module: ":timer", args: [_time, dest | _]}), do: dest
  defp destination(%{args: [dest | _]}), do: dest
  defp destination(_call), do: nil

  defp local_sends(_body, true = _module_defines_send, _issue_meta), do: []

  defp local_sends(body, false, issue_meta) do
    {_ast, issues} =
      Macro.prewalk(body, [], fn
        {:send, meta, [dest, _message]} = node, acc ->
          if to_self?(dest),
            do: {node, acc},
            else: {node, [issue(issue_meta, meta[:line], "send", "send/2") | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp to_self?({:self, _meta, args}) when args in [nil, []], do: true
  defp to_self?(_dest), do: false

  defp issue(issue_meta, line, trigger, what) do
    format_issue(issue_meta,
      message:
        "#{what} sends without waiting for an answer. Prefer GenServer.call (back pressure), " <>
          "or allow-list the module with the reason a cast or send is safe here.",
      trigger: trigger,
      line_no: line
    )
  end
end
