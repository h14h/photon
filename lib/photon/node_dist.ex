defmodule Photon.NodeDist do
  @moduledoc """
  The packaged node binaries the hub hands out (built by `mix photon.package`).
  Defaults to `node/dist`; override with `PHOTON_NODE_DIST`.
  """

  @targets ~w(linux-x86_64 linux-aarch64 macos-aarch64 macos-x86_64)

  def dir do
    Application.get_env(:photon, :node_dist_dir) || Path.expand("../../node/dist", __DIR__)
  end

  def targets, do: @targets

  @doc "The file for a target such as `linux-aarch64`, if it has been built."
  def binary(target) when target in @targets do
    path = Path.join(dir(), "photon-node-" <> target)
    if File.regular?(path), do: {:ok, path}, else: {:error, :not_built}
  end

  def binary(_target), do: {:error, :unknown_target}

  def available, do: Enum.filter(@targets, &match?({:ok, _}, binary(&1)))

  @doc "The version of the binaries this hub hands out, from `dist/VERSION`."
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
  def target(os, arch) do
    os = %{"Linux" => "linux", "Darwin" => "macos"}[os]

    arch =
      %{"x86_64" => "x86_64", "amd64" => "x86_64", "aarch64" => "aarch64", "arm64" => "aarch64"}[
        arch
      ]

    if os && arch, do: {:ok, "#{os}-#{arch}"}, else: :error
  end

  @doc "Which target to build for a missing binary, in `mix photon.package` terms."
  def package_target(target), do: String.replace(target, "-", "_")

  @template Path.expand("../../priv/node/install.sh.eex", __DIR__)
  @external_resource @template
  require EEx
  EEx.function_from_file(:defp, :render_script, @template, [:assigns])

  @doc "The install script, pointing at the hub's base URL."
  def install_script(base_url) do
    render_script(%{
      hub_http: sh_safe!(base_url),
      server_url: base_url |> Photon.Hub.node_socket_url() |> sh_safe!()
    })
  end

  # URLs are interpolated into single-quoted and double-quoted shell strings.
  defp sh_safe!(value) do
    if value =~ ~r/\A[A-Za-z0-9:\/._\-\[\]%]+\z/,
      do: value,
      else: raise(ArgumentError, "unexpected characters in hub URL #{inspect(value)}")
  end
end
