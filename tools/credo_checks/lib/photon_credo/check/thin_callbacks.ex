defmodule PhotonCredo.Check.ThinCallbacks do
  use Credo.Check,
    id: "PH0002",
    base_priority: :high,
    category: :refactor,
    param_defaults: [
      callbacks: [:handle_call, :handle_cast, :handle_info, :handle_continue],
      max_lines: 15,
      excluded_modules: []
    ],
    explanations: [
      check: """
      A server callback hands its message to the functional core and shapes
      the reply; it holds no business logic of its own (Designing Elixir
      Systems with OTP, rule 30 in docs/otp-design-guide.md). Putting logic
      inside the state loop "conflates two concerns: organization and
      concurrency".

      This check caps the body of every callback clause (`handle_call`,
      `handle_cast`, `handle_info`, `handle_continue` by default; framework
      callbacks such as `handle_in` or `handle_event` can be added) at
      `max_lines` lines. A longer clause usually means a decision that
      belongs in a pure function the callback calls.
      """,
      params: [
        callbacks: "Callback names whose clauses are capped.",
        max_lines: "The most lines a callback clause's body may have.",
        excluded_modules: "Module patterns this check skips."
      ]
    ]

  alias PhotonCredo.Ast

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    callbacks = Params.get(params, :callbacks, __MODULE__)
    max_lines = Params.get(params, :max_lines, __MODULE__)
    excluded = Params.get(params, :excluded_modules, __MODULE__)

    for info <- Ast.modules(SourceFile.ast(source_file)),
        not Ast.matches?(info.name, excluded),
        clause <- Ast.clauses(info),
        clause.kind == :def,
        clause.name in callbacks,
        clause.body_lines > max_lines do
      format_issue(issue_meta,
        message:
          "#{info.name}.#{clause.name}/#{clause.arity} has a #{clause.body_lines}-line clause " <>
            "(max #{max_lines}). Keep callbacks thin: move the decision into the functional " <>
            "core and have the callback call it and shape the reply.",
        trigger: Atom.to_string(clause.name),
        line_no: clause.line
      )
    end
  end
end
