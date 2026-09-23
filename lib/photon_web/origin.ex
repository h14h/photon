defmodule PhotonWeb.Origin do
  @moduledoc """
  Which browser origins may open the LiveView websocket (`check_origin`).

  Hosts only, since a TLS-terminating proxy changes the scheme and port the hub
  sees. Allowed: the configured public host, `localhost`, and the hub's own
  tailnet name and address. Deliberately not all of `*.ts.net`, which anyone
  can serve pages from with Tailscale Funnel.
  """

  def allowed?(%URI{host: host}) when is_binary(host) do
    host in static_hosts() or host in Photon.Tailnet.own_names()
  end

  def allowed?(_uri), do: false

  defp static_hosts do
    public = Application.get_env(:photon, PhotonWeb.Endpoint)[:url][:host]

    extra =
      for url <- [Application.get_env(:photon, :public_url)],
          is_binary(url),
          do: URI.parse(url).host

    Enum.reject([public, "localhost", "127.0.0.1" | extra], &is_nil/1)
  end
end
