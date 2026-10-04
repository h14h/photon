defmodule PhotonCredo.Check.EnforceKeys do
  use Credo.Check,
    id: "PH0008",
    base_priority: :normal,
    category: :warning,
    explanations: [
      check: """
      Use `@enforce_keys`, or `struct!/2` in a constructor, for struct fields
      that must be given (Designing Elixir Systems with OTP, rule 18 in
      docs/otp-design-guide.md). A default that slips through becomes a
      data integrity bug.

      A field listed without a default (`defstruct [:id, :name]`) is one
      that must be given. This check flags a `defstruct` or `defexception`
      with such fields unless the module sets `@enforce_keys` or has a
      `new` function that builds the struct with `struct!/2`. Fields with
      explicit defaults (`count: 0`, even `name: nil`) are a decision
      already made.
      """
    ]

  alias PhotonCredo.Ast

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    for info <- Ast.modules(SourceFile.ast(source_file)),
        {line, required} <- structs(info),
        required != [],
        not enforced?(info) do
      format_issue(issue_meta,
        message:
          "#{info.name}'s struct leaves #{Enum.map_join(required, ", ", &inspect/1)} without " <>
            "defaults. Add @enforce_keys, or build it only through a new function that calls struct!/2.",
        trigger: "defstruct",
        line_no: line
      )
    end
  end

  # `{line, fields without defaults}` for each defstruct/defexception.
  defp structs(info) do
    for {kind, meta, [fields]} <- Ast.top_level_forms(info.body),
        kind in [:defstruct, :defexception],
        is_list(fields) do
      {meta[:line], for(field <- fields, is_atom(field), do: field)}
    end
  end

  defp enforced?(info) do
    Enum.any?(Ast.top_level_forms(info.body), &enforce_keys?/1) or built_by_new?(info)
  end

  defp enforce_keys?({:@, _meta, [{:enforce_keys, _, [_keys]}]}), do: true
  defp enforce_keys?(_form), do: false

  defp built_by_new?(info) do
    info
    |> Ast.clauses()
    |> Enum.filter(&(&1.name == :new))
    |> Enum.any?(fn clause ->
      {_ast, found} =
        Macro.prewalk(clause.body, false, fn
          {:struct!, _meta, args} = node, _found when is_list(args) -> {node, true}
          node, found -> {node, found}
        end)

      found
    end)
  end
end
