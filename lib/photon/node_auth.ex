defmodule Photon.NodeAuth do
  @moduledoc """
  The shared secret agent nodes present when connecting (header
  `x-photon-token`). Taken from `PHOTON_NODE_TOKEN`, or generated once and
  kept in the data directory so remote nodes survive server restarts.
  """

  alias Photon.Paths

  def token do
    case :persistent_term.get({__MODULE__, :token}, nil) do
      nil ->
        token = load()
        :persistent_term.put({__MODULE__, :token}, token)
        token

      token ->
        token
    end
  end

  def valid?(given) when is_binary(given), do: Plug.Crypto.secure_compare(given, token())
  def valid?(_), do: false

  defp load do
    case System.get_env("PHOTON_NODE_TOKEN") do
      token when token not in [nil, ""] -> token
      _ -> read_or_create(Paths.node_token_file())
    end
  end

  defp read_or_create(path) do
    case File.read(path) do
      {:ok, token} when byte_size(token) > 0 ->
        String.trim(token)

      _ ->
        token = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, token)
        File.chmod!(path, 0o600)
        token
    end
  end
end
