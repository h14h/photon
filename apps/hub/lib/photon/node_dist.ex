defmodule Photon.NodeDist do
  @moduledoc """
  The packaged node binaries the hub hands out (built by `mix photon.package`).
  Defaults to `apps/node/dist`; override with `PHOTON_NODE_DIST`.
  """

  use Boundary, deps: [Photon.InstallScript]

  @targets ~w(linux-x86_64 linux-aarch64 macos-aarch64 macos-x86_64)

  @spec dir() :: Path.t()
  def dir do
    Application.get_env(:photon, :node_dist_dir) || Path.expand("../../../node/dist", __DIR__)
  end

  @spec targets() :: [String.t()]
  def targets, do: @targets

  @doc "The file for a target such as `linux-aarch64`, if it has been built."
  @spec binary(String.t()) :: {:ok, Path.t()} | {:error, :not_built | :unknown_target}
  def binary(target) when target in @targets do
    path = Path.join(dir(), "photon-node-" <> target)
    if File.regular?(path), do: {:ok, path}, else: {:error, :not_built}
  end

  def binary(_target), do: {:error, :unknown_target}

  @doc "The targets whose binary has been built."
  @spec available() :: [String.t()]
  def available, do: Enum.filter(@targets, &match?({:ok, _}, binary(&1)))

  @doc "The version of the binaries this hub hands out, from `dist/VERSION`."
  @spec version() :: String.t() | nil
  def version do
    case File.read(Path.join(dir(), "VERSION")) do
      {:ok, version} -> String.trim(version)
      {:error, _} -> nil
    end
  end

  @doc """
  Whether a connected node should be updated: it predates the capabilities
  list, or its build is older than the one this hub hands out. Current nodes
  without a build stamp (run from source, or embedded in the hub) aren't
  compared by build.
  """
  @spec outdated?(map(), String.t() | nil) :: boolean()
  def outdated?(node, latest \\ version()) do
    node["capabilities"] == nil or
      case {build_stamp(node["version"]), build_stamp(latest)} do
        {stamp, newest} when is_binary(stamp) and is_binary(newest) -> newest > stamp
        _ -> false
      end
  end

  # "0.1.0+20260923052345" -> "20260923052345"; stamps sort as strings.
  defp build_stamp(version) when is_binary(version) do
    case String.split(version, "+", parts: 2) do
      [_, stamp] -> stamp
      _ -> nil
    end
  end

  defp build_stamp(_), do: nil

  @doc "Maps `uname -s` and `uname -m` output to a target."
  @spec target(String.t() | nil, String.t() | nil) :: {:ok, String.t()} | :error
  def target(os, arch) do
    os = %{"Linux" => "linux", "Darwin" => "macos"}[os]

    arch =
      %{"x86_64" => "x86_64", "amd64" => "x86_64", "aarch64" => "aarch64", "arm64" => "aarch64"}[
        arch
      ]

    if os && arch, do: {:ok, "#{os}-#{arch}"}, else: :error
  end

  @doc "Which target to build for a missing binary, in `mix photon.package` terms."
  @spec package_target(String.t()) :: String.t()
  def package_target(target), do: String.replace(target, "-", "_")

  @doc "The install script, pointing at the hub's base URL (`Photon.InstallScript.render/1`)."
  @spec install_script(String.t()) :: String.t()
  defdelegate install_script(base_url), to: Photon.InstallScript, as: :render
end
