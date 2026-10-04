defmodule PhotonCredo.Check.StructType do
  use Credo.Check,
    id: "PH0018",
    base_priority: :normal,
    category: :readability,
    explanations: [
      check: """
      A struct is data other code depends on, so it names its shape: every
      module that defines a struct (`defstruct`, `defexception`, or an Ecto
      `schema`/`embedded_schema`) declares `@type t` (or `@opaque t`), and
      functions spec it as `t()` (Designing Elixir Systems with OTP, rules
      32, 39 and 69 in docs/otp-design-guide.md). Dialyzer and readers both
      use it.
      """
    ]

  alias PhotonCredo.Ast

  @struct_forms [:defstruct, :defexception, :schema, :embedded_schema]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    for info <- Ast.modules(SourceFile.ast(source_file)),
        {form, meta} <- struct_forms(info),
        not typed?(info) do
      format_issue(issue_meta,
        message: "#{info.name} defines a struct (#{form}) but no @type t. Name its shape.",
        trigger: Atom.to_string(form),
        line_no: meta[:line]
      )
    end
    |> Enum.uniq_by(& &1.line_no)
  end

  defp struct_forms(info) do
    for {form, meta, args} <- Ast.top_level_forms(info.body),
        form in @struct_forms,
        is_list(args),
        do: {form, meta}
  end

  defp typed?(info) do
    Enum.any?(Ast.top_level_forms(info.body), fn
      {:@, _, [{kind, _, [{:"::", _, [{:t, _, _} | _]}]}]} when kind in [:type, :opaque] -> true
      _ -> false
    end)
  end
end
