defmodule PhotonCredo.Check.LiveViewLogic do
  use Credo.Check,
    id: "PH0016",
    base_priority: :high,
    category: :design,
    param_defaults: [
      uses: [
        "Phoenix.LiveView",
        "Phoenix.LiveComponent",
        "Phoenix.Channel"
      ],
      forbidden: [
        "*.Repo",
        "Ecto",
        "Ecto.Query",
        "Ecto.Changeset",
        "Ecto.Multi",
        "File",
        "Port",
        "System.cmd",
        "System.shell",
        "Req",
        "Phoenix.PubSub",
        "GenServer",
        ":ets",
        ":persistent_term",
        ":gen_server"
      ]
    ],
    explanations: [
      check: """
      LiveViews and channels replace the server layer: their callbacks call
      the contexts' APIs and shape what the user sees, and hold no business
      logic (Designing Elixir Systems with OTP, rule 11 in
      docs/otp-design-guide.md, and the moduledoc of `Photon`).

      In a module that `use`s one of `uses` (`Phoenix.LiveView`, or
      `use PhotonWeb, :live_view` when configured as `{"PhotonWeb",
      :live_view}`), this check flags persistence, I/O and messaging
      infrastructure: repos, Ecto queries and changesets, files, ports,
      shell commands, HTTP, PubSub (subscribe through the context) and
      GenServer calls. Those belong in a context the LiveView calls.
      """,
      params: [
        uses: "`use` targets that make a module a LiveView: `\"Mod\"` or `{\"Mod\", :option}`.",
        forbidden: "Calls a LiveView may not make: `\"Mod\"`, `\"Mod.fun\"`, `\"*.Suffix\"`."
      ]
    ]

  alias PhotonCredo.Ast

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    uses = Params.get(params, :uses, __MODULE__)
    forbidden = Enum.map(Params.get(params, :forbidden, __MODULE__), &Ast.normalize/1)

    for info <- Ast.modules(SourceFile.ast(source_file)),
        live_view?(info, uses),
        issue <-
          call_issues(info, forbidden, issue_meta) ++ import_issues(info, forbidden, issue_meta),
        do: issue
  end

  defp live_view?(info, uses) do
    info.body
    |> Ast.top_level_forms()
    |> Enum.any?(fn
      {:use, _meta, [target | opts]} -> use_matches?(Ast.resolve(target, info), opts, uses)
      _ -> false
    end)
  end

  defp use_matches?(module, opts, uses) do
    Enum.any?(uses, fn
      {use_module, option} -> Ast.normalize(use_module) == module and opts == [option]
      use_module -> Ast.normalize(use_module) == module
    end)
  end

  defp call_issues(info, forbidden, issue_meta) do
    for call <- Ast.remote_calls(info.body, info), forbidden?(call, forbidden) do
      issue(issue_meta, info, "#{call.module}.#{call.function}", call.line)
    end
  end

  defp import_issues(info, forbidden, issue_meta) do
    for {:import, meta, [target | _]} <- Ast.top_level_forms(info.body),
        module = Ast.resolve(target, info),
        module in forbidden do
      issue(issue_meta, info, "import #{module}", meta[:line])
    end
  end

  defp forbidden?(call, forbidden) do
    name = "#{call.module}.#{call.function}"

    Enum.any?(forbidden, fn
      "*." <> suffix -> call.module == suffix or String.ends_with?(call.module, "." <> suffix)
      entry -> call.module == entry or name == entry
    end)
  end

  defp issue(issue_meta, info, what, line) do
    format_issue(issue_meta,
      message:
        "#{info.name} uses #{what}. Keep business logic, persistence and I/O in a context: " <>
          "a LiveView maps events to context calls and context data to assigns.",
      trigger: what |> String.split([".", " "]) |> List.last(),
      line_no: line
    )
  end
end
