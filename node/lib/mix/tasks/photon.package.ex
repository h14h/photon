defmodule Mix.Tasks.Photon.Package do
  @shortdoc "Builds self-contained photon-node executables for each platform"

  @moduledoc """
  Builds single-file node executables into `node/dist/`, one per target in
  `mix.exs`. Each carries its own Erlang runtime and a static
  `unreal-agent-runner`, so the target machine needs nothing installed.

      mix photon.package
      mix photon.package --targets linux_x86_64,macos_aarch64
      mix photon.package --ref v0.1.0 --source ~/src/unreal-agent
      mix photon.package --prebuilt-runners   # runners already in _build/runners/<target>/

  Needs Go 1.27+, xz and the Zig version Burrito requires (0.16.0 for
  Burrito 1.6) on the build machine. Burrito downloads a
  prebuilt Erlang runtime per target that matches the build machine's exact
  OTP version, so build with an OTP release it has, for example:

      mise exec erlang@29.1 zig@0.16.0 -- mix photon.package
  """

  use Mix.Task

  alias Mix.Tasks.Photon.BuildRunner

  @erts_url "https://beam-machine-universal.b-cdn.net/OTP-{v}/linux/x86_64/any/otp_{v}_linux_any_x86_64.tar.gz"

  defmodule QuietStream do
    @moduledoc false
    # Passes build output through, minus Burrito's per-file progress counter.
    defstruct []

    defimpl Collectable do
      def into(stream) do
        {stream,
         fn
           stream, {:cont, chunk} ->
             IO.write(String.replace(chunk, ~r/info: 🔍 Files Packed: \d+/u, ""))
             stream

           stream, _ ->
             stream
         end}
      end
    end
  end

  @node_dir Path.expand("../../..", __DIR__)

  @impl true
  def run(argv) do
    # From the hub project, hand over to the node project, which owns the release.
    if Mix.Project.config()[:app] != :photon_node do
      BuildRunner.cmd!("mix", ["photon.package" | argv], cd: @node_dir)
    else
      package(argv)
    end
  end

  defp package(argv) do
    {opts, _} =
      OptionParser.parse!(argv,
        strict: [targets: :string, ref: :string, source: :string, prebuilt_runners: :boolean]
      )

    targets = release_targets(opts[:targets])
    if targets == [], do: Mix.raise("No targets match #{opts[:targets]}")

    check_tools!(if opts[:prebuilt_runners], do: ~w(zig xz), else: ~w(go zig xz))
    check_erts!()

    if opts[:prebuilt_runners] do
      # Runners built elsewhere (the Dockerfile's Go stage) into _build/runners.
      for {name, _} <- targets, !File.exists?(PhotonNode.Package.runner_path(name)) do
        Mix.raise("--prebuilt-runners, but #{PhotonNode.Package.runner_path(name)} is missing")
      end
    else
      source = BuildRunner.source(opts)

      for {name, target} <- targets do
        Mix.shell().info("Building unreal-agent-runner for #{name}")

        BuildRunner.go_build!(
          source,
          PhotonNode.Package.runner_path(name),
          PhotonNode.Package.go_env(target)
        )
      end
    end

    build = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
    File.rm_rf!("_build/prod/rel/photon_node")

    Mix.shell().info(
      "Assembling and wrapping the release (build #{build}); this takes a few minutes"
    )

    env = [
      {"MIX_ENV", "prod"},
      {"PHOTON_PACKAGE_TARGETS", target_list(targets)},
      {"PHOTON_BUILD", build}
    ]

    # compile --force: this task already compiled the app without the build
    # stamp, and in prod that shares a build directory with the release, which
    # would otherwise keep the stale version.
    args = ~w(do compile --force + release photon_node --overwrite)

    case System.cmd("mix", args,
           env: env,
           stderr_to_stdout: true,
           into: %QuietStream{}
         ) do
      {_, 0} -> :ok
      {_, status} -> Mix.raise("mix release exited with #{status}")
    end

    collect(targets, Mix.Project.config()[:version] <> "+" <> build)
  end

  defp release_targets(only) do
    only = only && String.split(only, ",", trim: true)
    targets = Mix.Project.config()[:releases][:photon_node][:burrito][:targets]
    Enum.filter(targets, fn {name, _} -> only == nil or to_string(name) in only end)
  end

  defp target_list(targets), do: Enum.map_join(targets, ",", fn {name, _} -> name end)

  defp check_tools!(tools) do
    zig = Version.to_string(Burrito.get_versions().zig)

    for tool <- tools, !System.find_executable(tool) do
      Mix.raise("#{tool} is required on PATH to package nodes (Burrito needs Zig #{zig})")
    end

    {version, 0} = System.cmd("zig", ["version"])

    unless String.trim(version) == zig do
      Mix.raise("Burrito needs Zig #{zig}, found #{String.trim(version)}")
    end
  end

  # Burrito fetches runtimes for the host's exact OTP version and fails
  # obscurely when none exist, so check first.
  defp check_erts! do
    version = otp_version()
    # Req comes with Burrito.
    {:ok, _} = Application.ensure_all_started(:req)

    case Req.head(String.replace(@erts_url, "{v}", version), retry: false) do
      {:ok, %{status: 200}} ->
        :ok

      other ->
        Mix.raise("""
        Burrito has no prebuilt Erlang runtime for OTP #{version} (#{inspect(other)}).
        Build with a published OTP release instead, e.g.:

            mise exec erlang@29.1 zig@#{Version.to_string(Burrito.get_versions().zig)} -- mix photon.package
        """)
    end
  end

  defp otp_version do
    [:code.root_dir(), "releases", :erlang.system_info(:otp_release), "OTP_VERSION"]
    |> Path.join()
    |> File.read!()
    |> String.trim()
  end

  defp collect(targets, version) do
    File.mkdir_p!("dist")

    sums =
      for {name, _} <- targets do
        out =
          Path.join(
            "dist",
            "photon-node-" <> String.replace(to_string(name), "_", "-", global: false)
          )

        File.cp!(Path.join("burrito_out", "photon_node_#{name}"), out)
        File.chmod!(out, 0o755)
        hash = :crypto.hash(:sha256, File.read!(out)) |> Base.encode16(case: :lower)
        size = File.stat!(out).size
        Mix.shell().info([:green, "  #{out}", :reset, "  #{div(size, 1_048_576)} MB"])
        "#{hash}  #{Path.basename(out)}\n"
      end

    File.write!("dist/SHA256SUMS", sums)
    # The hub reads this to tell which connected nodes are out of date.
    File.write!("dist/VERSION", version <> "\n")
  end
end
