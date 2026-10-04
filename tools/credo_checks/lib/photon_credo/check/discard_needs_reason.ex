defmodule PhotonCredo.Check.DiscardNeedsReason do
  use Credo.Check,
    id: "PH0019",
    base_priority: :high,
    category: :warning,
    param_defaults: [allowed: []],
    explanations: [
      check: """
      Dropping a result is a decision, so it says why (rules 72 and 95 in
      docs/otp-design-guide.md: handle the tagged results of a boundary).

      Elixir reports most failures as `{:error, reason}` rather than raising,
      so a dropped result can be a dropped error. Dialyzer's
      `:unmatched_returns` makes every ignored result explicit; this check
      makes every explicit discard explain itself:

        * `_ = expr` always needs a reason: a comment on the line above (or
          at the end of the line).
        * `_name = expr` needs one too, unless `expr` can't carry an error:
          a call to a raising function (`name!`), or a call into a module
          listed under `allowed`, with the reason its results are safe to
          drop.

      Better than either: return `:ok` from a helper that handles the error
      once (see `Photon.Events`).
      """,
      params: [
        allowed:
          "`[{module_pattern, \"reason\"}]`: modules whose results never carry an error, " <>
            "so a named discard of them needs no comment."
      ]
    ]

  alias PhotonCredo.Ast

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    allowed = Params.get(params, :allowed, __MODULE__)
    lines = source_file |> SourceFile.lines() |> Map.new()

    for info <- Ast.modules(SourceFile.ast(source_file)),
        {kind, line, rhs} <- discards(info.body),
        not explained?(lines, line),
        not safe?(kind, rhs, info, allowed) do
      format_issue(issue_meta,
        message: message(kind),
        trigger: "_",
        line_no: line
      )
    end
  end

  defp message(:bare),
    do: "Say why this result can be dropped: a comment above `_ = ...`, or handle it."

  defp message(:named),
    do:
      "A named discard of a result that may be an error needs a reason comment above it, " <>
        "or use the raising version of the call."

  # `_ = rhs` and `_name = rhs`, with the line of the match.
  defp discards(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {:=, meta, [{name, _, ctx}, rhs]} = node, acc when is_atom(name) and is_atom(ctx) ->
          {node, add_discard(acc, Atom.to_string(name), meta[:line], rhs)}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  # `__MODULE__ = ...` and friends are assertions, not discards.
  defp add_discard(acc, "__" <> _special, _line, _rhs), do: acc
  defp add_discard(acc, "_", line, rhs), do: [{:bare, line, rhs} | acc]
  defp add_discard(acc, "_" <> _name, line, rhs), do: [{:named, line, rhs} | acc]
  defp add_discard(acc, _name, _line, _rhs), do: acc

  defp safe?(:bare, _rhs, _info, _allowed), do: false
  defp safe?(:named, rhs, info, allowed), do: raising?(rhs) or allowed_call?(rhs, info, allowed)

  defp raising?({{:., _, [_mod, fun]}, _, args}) when is_atom(fun) and is_list(args),
    do: bang?(fun)

  defp raising?({fun, _, args}) when is_atom(fun) and is_list(args), do: bang?(fun)
  defp raising?(_rhs), do: false

  defp bang?(fun), do: fun |> Atom.to_string() |> String.ends_with?("!")

  defp allowed_call?({{:., _, [mod, fun]}, _, args}, info, allowed)
       when is_atom(fun) and is_list(args) do
    case Ast.resolve(mod, info) do
      nil -> false
      module -> Ast.allowed_with_reason?(module, allowed)
    end
  end

  defp allowed_call?(_rhs, _info, _allowed), do: false

  # A comment at the end of the line, or a comment line directly above.
  defp explained?(lines, line) do
    trailing_comment?(Map.get(lines, line, "")) or comment_above?(lines, line - 1)
  end

  defp trailing_comment?(text), do: Regex.match?(~r/\s#(\s|$)/, text)

  defp comment_above?(_lines, 0), do: false

  defp comment_above?(lines, line) do
    text = lines |> Map.get(line, "") |> String.trim()
    String.starts_with?(text, "#") and not String.contains?(text, "credo:")
  end
end
