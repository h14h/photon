defmodule PhotonCredo.Check.EnforceKeys do
  use Credo.Check,
    id: "PH0008",
    base_priority: :normal,
    category: :warning,
    explanations: [
      check: """
      Struct fields that must be given are listed in `@enforce_keys`
      (Designing Elixir Systems with OTP, rule 18 in
      docs/otp-design-guide.md). A default that slips through becomes a
      data integrity bug.

      A field listed without a default (`defstruct [:id, :name]`) is one
      that must be given, so this check flags each such field of a
      `defstruct` or `defexception` that `@enforce_keys` leaves out. A field
      that may be left out says so with an explicit default (`count: 0`,
      even `name: nil`). A constructor that calls `struct!/2` doesn't
      count: it enforces only the keys the struct declares.
      """
    ]

  alias PhotonCredo.Ast

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    for info <- Ast.modules(SourceFile.ast(source_file)),
        {:ok, enforced} <- [enforced_keys(info)],
        {line, required} <- structs(info),
        missing = required -- enforced,
        missing != [] do
      format_issue(issue_meta,
        message:
          "#{info.name}'s struct leaves #{Enum.map_join(missing, ", ", &inspect/1)} without " <>
            "defaults and out of @enforce_keys. Enforce them, or give the optional ones an " <>
            "explicit default (`name: nil`).",
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

  # The keys `@enforce_keys` lists, `{:ok, []}` without it, or `:error` when
  # the value isn't a literal list this check can read.
  defp enforced_keys(info) do
    info.body
    |> Ast.top_level_forms()
    |> Enum.find_value({:ok, []}, fn
      {:@, _meta, [{:enforce_keys, _, [keys]}]} -> literal_keys(keys)
      _form -> nil
    end)
  end

  defp literal_keys(keys) when is_list(keys) do
    if Enum.all?(keys, &is_atom/1), do: {:ok, keys}, else: :error
  end

  defp literal_keys(_keys), do: :error
end
