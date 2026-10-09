defmodule PhotonCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :photon_core,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      # The custom Credo checks in tools/credo_checks are tested here.
      test_paths: ["test", "../../tools/credo_checks/test"],
      start_permanent: Mix.env() == :prod,
      # Boundary checks the layering on every compile; `mix compile
      # --warnings-as-errors` (part of `mix precommit`) fails on a violation.
      compilers: [:boundary] ++ Mix.compilers(),
      aliases: aliases(),
      # `mix dialyzer` (see AGENTS.md); its PLTs live under _build.
      dialyzer: dialyzer(),
      deps: deps(),
      test_coverage: [
        summary: [threshold: 95],
        ignore_modules: test_support_modules()
      ]
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  # A library: no `:mod`, so no application callback and no processes.
  def application do
    [extra_applications: [:logger]]
  end

  # Every module under test/support is test code, so coverage leaves it out
  # without a list to keep in step.
  defp test_support_modules do
    for path <- Path.wildcard("test/support/**/*.ex"),
        [_, name] <- Regex.scan(~r/^defmodule ([\w.]+) do/m, File.read!(path)),
        do: Module.concat([name])
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.7"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.18", only: :test},
      {:stream_data, "~> 1.1", only: :test},
      {:boundary, "~> 0.10", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      # Every check, in the test env (see cli/0). Boundary violations and
      # type warnings fail the compile; `mix format` fixes what the format
      # check reports; xref fails on any compile-time dependency cycle.
      # `mix dialyzer` and the coverage threshold are separate (see AGENTS.md
      # and scripts/verify).
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "format --check-formatted",
        "credo --strict",
        "xref graph --format cycles --label compile-connected --fail-above 0",
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
