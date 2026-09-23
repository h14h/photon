defmodule PhotonNode.MixProject do
  use Mix.Project

  def project do
    [
      app: :photon_node,
      version: version(),
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  # `mix photon.package` builds these into single-file executables that carry
  # their own Erlang runtime and unreal-agent-runner, so a target machine needs
  # nothing installed. PHOTON_PACKAGE_TARGETS=linux_x86_64,... limits the set.
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
            Enum.filter(@targets, fn {name, _} -> only == nil or to_string(name) in only end),
          extra_steps: [patch: [post: [PhotonNode.Package.RunnerStep]]]
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

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {PhotonNode.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:slipstream, "~> 1.2"},
      {:jason, "~> 1.4"},
      {:burrito, "~> 1.6", runtime: false}
    ]
  end
end
