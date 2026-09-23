defmodule Mix.Tasks.Photon.BuildRunner do
  @shortdoc "Clones unreal-agent and builds unreal-agent-runner into priv/bin"

  @moduledoc """
  Fetches https://github.com/unreallabsai/unreal-agent and builds its runner
  with Go 1.27+, placing the binary in the node's `priv/bin/unreal-agent-runner`.
  Works from the node project or from the GUI project that embeds it.

      mix photon.build_runner              # latest main
      mix photon.build_runner --ref v0.1.0 # a tag, branch or commit
      mix photon.build_runner --source ~/src/unreal-agent

  `--source` builds from an existing checkout instead of cloning.
  """

  use Mix.Task

  @repo "https://github.com/unreallabsai/unreal-agent"
  @output Path.expand("../../../priv/bin/unreal-agent-runner", __DIR__)

  @impl true
  def run(argv) do
    {opts, _} = OptionParser.parse!(argv, strict: [ref: :string, source: :string])

    source = source(opts)
    Mix.shell().info("Building #{@output}")
    go_build!(source, @output, [{"CGO_ENABLED", "0"}])
    Mix.shell().info([:green, "Built unreal-agent-runner."])
  end

  @doc false
  # The unreal-agent source: `--source <dir>`, or a checkout of `--ref`.
  def source(opts) do
    if dir = opts[:source], do: Path.expand(dir), else: checkout(opts[:ref])
  end

  @doc false
  # Builds a static runner (upstream's Dockerfile also uses CGO_ENABLED=0).
  def go_build!(source, output, env) do
    go = System.find_executable("go") || Mix.raise("Go 1.27+ is required: https://go.dev/dl/")
    File.mkdir_p!(Path.dirname(output))
    args = ["build", "-trimpath", "-buildvcs=false", "-o", output, "./cmd/unreal-agent-runner"]
    cmd!(go, args, cd: source, env: env)
  end

  defp checkout(ref) do
    git = System.find_executable("git") || Mix.raise("git is required to fetch unreal-agent")
    dir = Path.expand("_build/unreal-agent-src")

    if File.dir?(Path.join(dir, ".git")) do
      Mix.shell().info("Updating #{dir}")
      cmd!(git, ["fetch", "--tags", "origin"], cd: dir)
    else
      Mix.shell().info("Cloning #{@repo}")
      cmd!(git, ["clone", @repo, dir])
    end

    cmd!(git, ["checkout", "--detach", ref || "origin/HEAD"], cd: dir)
    dir
  end

  @doc false
  def cmd!(exe, args, opts \\ []) do
    case System.cmd(exe, args, [into: IO.stream(), stderr_to_stdout: true] ++ opts) do
      {_, 0} ->
        :ok

      {_, status} ->
        Mix.raise("#{Path.basename(exe)} #{Enum.join(args, " ")} exited with #{status}")
    end
  end
end
