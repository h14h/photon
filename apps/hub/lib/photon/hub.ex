defmodule Photon.Hub do
  @moduledoc """
  How nodes reach this hub.

  `PHOTON_PUBLIC_URL` sets it explicitly, for example when the hub sits behind
  `tailscale serve` or a TLS proxy (`https://hub.example.ts.net`). Otherwise it
  is the hub's MagicDNS name on the tailnet, plus the port it listens on, and
  failing that, its public URL in production (`https://$PHX_HOST`).
  """

  use Boundary, deps: [Photon.InstallScript]

  @doc "Base HTTP URL for nodes, or `{:error, reason}` if nodes couldn't reach it."
  @spec public_url(%{dns: String.t()} | nil | false) ::
          {:ok, String.t()} | {:error, :loopback | :no_address}
  def public_url(tailnet_self \\ nil) do
    cond do
      url = Application.get_env(:photon, :public_url) ->
        {:ok, String.trim_trailing(url, "/")}

      loopback?() ->
        {:error, :loopback}

      tailnet_self && tailnet_self.dns != "" ->
        {:ok, "http://#{tailnet_self.dns}:#{port()}"}

      url = Application.get_env(:photon, :fallback_url) ->
        {:ok, url}

      true ->
        {:error, :no_address}
    end
  end

  @doc "The websocket URL a node connects to, given the hub's base URL (`Photon.InstallScript.socket_url/1`)."
  @spec node_socket_url(String.t()) :: String.t()
  defdelegate node_socket_url(base), to: Photon.InstallScript, as: :socket_url

  @spec port() :: :inet.port_number()
  def port, do: endpoint_http()[:port] || 4000

  @doc "Whether the endpoint listens only on this machine."
  @spec loopback?() :: boolean()
  def loopback? do
    case endpoint_http()[:ip] do
      {127, _, _, _} -> true
      {0, 0, 0, 0, 0, 0, 0, 1} -> true
      _ -> false
    end
  end

  defp endpoint_http, do: Application.get_env(:photon, PhotonWeb.Endpoint)[:http] || []
end
