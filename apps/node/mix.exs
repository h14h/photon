defmodule PhotonNode.MixProject do
  use Mix.Project

  def project do
    [
      app: :photon_node,
      version: version(),
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      # Boundary checks the layering on every compile; `mix compile
      # --warnings-as-errors` (part of `mix precommit`) fails on a violation.
      compilers: [:boundary] ++ Mix.compilers(),
      deps: deps(),
      aliases: aliases(),
      # `mix dialyzer` (see AGENTS.md); its PLTs live under _build.
      dialyzer: dialyzer(),
      elixirc_paths: elixirc_paths(Mix.env()),
      releases: releases(),
      test_coverage: [
        summary: [threshold: 85],
        # Test support, plus the packaged entry point and the packaging task:
        # they halt the VM or drive Burrito and Zig, so no test runs them.
        ignore_modules: [
          PhotonNode.CLI,
          Mix.Tasks.Photon.Package,
          Mix.Tasks.Photon.Package.QuietStream,
          Collectable.Mix.Tasks.Photon.Package.QuietStream
          | test_support_modules()
        ]
      ]
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  # `mix photon.package` builds these into single-file executables that carry
  # their own Erlang runtime, so a target machine needs nothing installed.
  # PHOTON_PACKAGE_TARGETS=linux_x86_64,... limits the set.
  @targets [
    linux_x86_64: [os: :linux, cpu: :x86_64],
    linux_aarch64: [os: :linux, cpu: :aarch64],
    macos_aarch64: [os: :darwin, cpu: :aarch64],
    macos_x86_64: [os: :darwin, cpu: :x86_64]
  ]

  defp releases do
    only = System.get_env("PHOTON_PACKAGE_TARGETS")
    only = only && String.split(only, ",", trim: true)

    [
      photon_node: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets:
            Enum.filter(@targets, fn {name, _} -> only == nil or to_string(name) in only end)
        ]
      ]
    ]
  end

  # Packaged builds carry a build stamp (set by `mix photon.package`), since a
  # packaged binary unpacks into a directory named after its version and would
  # otherwise keep running an older build's code.
  defp version do
    case System.get_env("PHOTON_BUILD") do
      nil -> "0.1.0"
      build -> "0.1.0+" <> build
    end
  end

  # Every module test/support defines is test code, so coverage leaves it
  # out without a list to keep in step. Read from the parsed code, so a
  # `defmodule` inside a string doesn't count.
  defp test_support_modules do
    for path <- Path.wildcard("test/support/**/*.ex"),
        module <- defined_modules(path |> File.read!() |> Code.string_to_quoted!()),
        do: module
  end

  defp defined_modules(ast) do
    {_ast, modules} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [{:__aliases__, _, parts} | _]} = node, acc ->
          {node, [Module.concat(parts) | acc]}

        node, acc ->
          {node, acc}
      end)

    modules
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {PhotonNode.Application, []}
    ]
  end

  defp aliases do
    [
      # Every check, in the test env (see cli/0). Boundary violations and
      # type warnings fail the compile; `mix format` fixes what the format
      # check reports; xref fails on a new compile-time dependency cycle
      # (the one allowed: `PhotonNode.Config`'s struct names its default hub
      # link, `Connection`). `mix dialyzer` and the coverage threshold are
      # separate (see AGENTS.md and scripts/verify).
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "format --check-formatted",
        "credo --strict",
        "xref graph --format cycles --label compile-connected --fail-above 1",
        "test --warnings-as-errors"
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:photon_core, path: "../core"},
      {:slipstream, "~> 1.2"},
      {:jason, "~> 1.4"},
      {:burrito, "~> 1.6", runtime: false},
      {:stream_data, "~> 1.1", only: :test},
      {:boundary, "~> 0.10", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp dialyzer do
    [
      # The OTP and Elixir PLT is shared by the three apps (repo root _build/).
      plt_core_path: "../../_build/plts",
      plt_local_path: "_build/plts",
      plt_add_apps: [:ex_unit, :mix, :burrito],
      ignore_warnings: ".dialyzer_ignore.exs",
      list_unused_filters: true,
      flags: [:error_handling, :extra_return, :missing_return, :unmatched_returns]
    ]
  end
end
