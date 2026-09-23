defmodule PhotonNode.Package do
  @moduledoc """
  Helpers for self-contained node executables; see `mix photon.package`.

  Targets are declared in `mix.exs`, since Burrito reads them from the release
  config. Each gets its own static `unreal-agent-runner` (Go, `CGO_ENABLED=0`),
  injected by `RunnerStep` after Burrito copies in that target's Erlang runtime.
  """

  @doc "Go's name for a Burrito target's OS and CPU."
  def go_env(target) do
    goos = %{linux: "linux", darwin: "darwin"} |> Map.fetch!(target[:os])
    goarch = %{x86_64: "amd64", aarch64: "arm64"} |> Map.fetch!(target[:cpu])
    [{"GOOS", goos}, {"GOARCH", goarch}, {"CGO_ENABLED", "0"}]
  end

  @doc "Where `mix photon.package` leaves the runner for a target."
  def runner_path(name) do
    Path.expand("../../_build/runners/#{name}/unreal-agent-runner", __DIR__)
  end

  defmodule RunnerStep do
    @moduledoc false
    # A Burrito build step (patch phase): puts the target's runner into the
    # release's priv/bin, where PhotonNode.Runner looks for it.

    def execute(context) do
      name = context.target.alias
      source = PhotonNode.Package.runner_path(name)

      unless File.exists?(source) do
        raise "No runner built for #{name} at #{source}. Build with `mix photon.package`."
      end

      # The app's own version, which is what names its directory in the release.
      vsn = to_string(context.mix_release.applications[:photon_node][:vsn])
      app_dir = Path.join(context.work_dir, "lib/photon_node-#{vsn}")

      unless File.dir?(app_dir) do
        raise "photon_node isn't at #{app_dir} in the release; not packaging a node without its runner"
      end

      dest = Path.join(app_dir, "priv/bin/unreal-agent-runner")
      File.mkdir_p!(Path.dirname(dest))
      File.cp!(source, dest)
      File.chmod!(dest, 0o755)
      context
    end
  end
end
