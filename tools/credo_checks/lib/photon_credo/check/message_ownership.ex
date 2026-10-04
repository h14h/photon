defmodule PhotonCredo.Check.MessageOwnership do
  use Credo.Check,
    id: "PH0004",
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      Hide a server's message formats behind client functions in the
      server's own module (Designing Elixir Systems with OTP, rule 63 in
      docs/otp-design-guide.md). Callers call `Counter.increment(name)`;
      they never write `GenServer.call(name, {:increment, 1})`, which would
      couple every caller to the server's internals.

      This check flags `GenServer.call`/`cast` (and `:gen_server`'s) with a
      literal message, an atom or a tuple tagged with an atom, in a module
      that has no `handle_call`/`handle_cast` clause for that message.
      """
    ]

  alias PhotonCredo.Ast

  @messengers %{
    {"GenServer", :call} => :handle_call,
    {"GenServer", :cast} => :handle_cast,
    {":gen_server", :call} => :handle_call,
    {":gen_server", :cast} => :handle_cast
  }

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    source_file
    |> SourceFile.ast()
    |> Ast.modules()
    |> Enum.flat_map(&module_issues(&1, issue_meta))
  end

  defp module_issues(info, issue_meta) do
    clauses = Ast.clauses(info)

    for call <- Ast.remote_calls(info.body, info),
        callback = Map.get(@messengers, {call.module, call.function}),
        callback != nil,
        tag = message_tag(call.args),
        tag != nil,
        not handles?(clauses, callback, tag) do
      format_issue(issue_meta,
        message:
          "#{call.module}.#{call.function} sends the message #{inspect(tag)}, which #{info.name} " <>
            "doesn't handle. Call a client function in the server's module instead, so the " <>
            "message format stays private to it.",
        trigger: Atom.to_string(call.function),
        line_no: call.line
      )
    end
  end

  # The message is the second argument (after the server).
  defp message_tag([_server, message | _]), do: tag(message)
  defp message_tag(_args), do: nil

  defp tag(atom) when is_atom(atom) and atom not in [nil, true, false], do: atom
  defp tag({tag, _second}) when is_atom(tag) and tag not in [nil, true, false], do: tag
  defp tag({:{}, _meta, [tag | _]}) when is_atom(tag) and tag not in [nil, true, false], do: tag
  defp tag(_message), do: nil

  defp handles?(clauses, callback, tag) do
    Enum.any?(clauses, fn clause ->
      clause.kind == :def and clause.name == callback and
        matches_tag?(List.first(clause.args), tag)
    end)
  end

  defp matches_tag?(pattern, tag), do: pattern |> unwrap_match() |> pattern_tag() |> accepts?(tag)

  # `{:msg, x} = message` matches what its left side does.
  defp unwrap_match({:=, _meta, [left, right]}) do
    case pattern_tag(left) do
      :any -> unwrap_match(right)
      _tag -> left
    end
  end

  defp unwrap_match(pattern), do: pattern

  defp pattern_tag({name, _meta, context}) when is_atom(name) and is_atom(context), do: :any
  defp pattern_tag(pattern), do: tag(pattern)

  defp accepts?(:any, _tag), do: true
  defp accepts?(tag, tag), do: true
  defp accepts?(_pattern_tag, _tag), do: false
end
