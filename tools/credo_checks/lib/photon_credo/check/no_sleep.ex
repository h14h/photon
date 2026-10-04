defmodule PhotonCredo.Check.NoSleep do
  use Credo.Check,
    id: "PH0005",
    base_priority: :high,
    category: :warning,
    param_defaults: [allowed: []],
    explanations: [
      check: """
      Don't sleep (Designing Elixir Systems with OTP, rules 55 and 96 in
      docs/otp-design-guide.md):

        * in tests, sleep too long and the suite is slow, too short and it
          flakes. Wait for a notification with `assert_receive`, or poll
          with a bounded "eventually".
        * in a process, a sleeping process can't read its mailbox. Schedule
          with `Process.send_after/3` or a GenServer timeout.

      This check flags `Process.sleep/1` and `:timer.sleep/1`. A sleep in a
      process that has no mailbox to read (a task) can be allowed: list the
      module under `allowed` with the reason.
      """,
      params: [
        allowed: "`[{module_pattern, \"reason\"}]`: modules whose sleeps are deliberate."
      ]
    ]

  alias PhotonCredo.Ast

  @sleeps [{"Process", :sleep}, {":timer", :sleep}]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    allowed = Params.get(params, :allowed, __MODULE__)

    for info <- Ast.modules(SourceFile.ast(source_file)),
        not Ast.allowed_with_reason?(info.name, allowed),
        call <- Ast.remote_calls(info.body, info),
        {call.module, call.function} in @sleeps do
      format_issue(issue_meta,
        message:
          "#{call.module}.sleep/1 in #{info.name}. Wait for a message (assert_receive, " <>
            "Process.send_after/3) instead, or allow-list the module with the reason.",
        trigger: "sleep",
        line_no: call.line
      )
    end
  end
end
