defmodule Photon.MixProject do
  use Mix.Project

  def project do
    [
      app: :photon,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      # `mix dialyzer` (see AGENTS.md); its PLTs live under _build.
      dialyzer: dialyzer(),
      deps: deps(),
      # Boundary checks the layering on every compile; `mix compile
      # --warnings-as-errors` (part of `mix precommit`) fails on a violation.
      compilers: [:boundary, :phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      test_coverage: [
        summary: [threshold: 85],
        # Test support, and the Phoenix scaffolding no test drives.
        ignore_modules: [
          Photon.Case,
          Photon.DataCase,
          Photon.Eventually,
          Photon.Fixtures,
          Photon.HarnessProfiles,
          Photon.HarnessProfiles.Block,
          Photon.HarnessProfiles.Loop,
          Photon.Property.SlowProfile,
          Photon.TestProfile,
          Photon.TestProfile.Wait,
          PhotonWeb.ConnCase,
          PhotonWeb,
          PhotonWeb.Telemetry
        ]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Photon.Application, []},
      # xmerl lets the installer tests check the generated launchd plist.
      extra_applications:
        [:logger, :runtime_tools] ++ if(Mix.env() == :test, do: [:xmerl], else: [])
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:photon_core, path: "../core"},
      # The hub can run a node in its own VM (`PHOTON_LOCAL_NODE`), handy in development.
      {:photon_node, path: "../node"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.22"},
      {:mdex, "~> 0.13.5"},
      {:phoenix, "~> 1.8.14"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:stream_data, "~> 1.1", only: :test},
      {:boundary, "~> 0.10", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind photon", "esbuild photon"],
      "assets.deploy": [
        "tailwind photon --minify",
        "esbuild photon --minify",
        "phx.digest"
      ],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      # Every check, in the test env (see cli/0). Boundary violations and
      # type warnings fail the compile; `mix format` fixes what the format
      # check reports. `mix dialyzer` is separate (see AGENTS.md).
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "format --check-formatted",
        "credo --strict",
        "test --warnings-as-errors"
      ]
    ]
  end

  defp dialyzer do
    [
      # The OTP and Elixir PLT is shared by the three apps (repo root _build/).
      plt_core_path: "../../_build/plts",
      plt_local_path: "_build/plts",
      plt_add_apps: [:ex_unit, :mix],
      ignore_warnings: ".dialyzer_ignore.exs",
      list_unused_filters: true,
      flags: [:error_handling, :extra_return, :missing_return, :unmatched_returns]
    ]
  end
end
