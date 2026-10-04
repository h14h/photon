defmodule PhotonWeb.ClientIP do
  @moduledoc """
  Where a browser or node connected from, for `PhotonWeb.Auth` and the
  node endpoints.

  The hub sits behind a TLS proxy on its own machine (Caddy, or
  `tailscale serve`), so a request from loopback is the proxy's, and its
  last `X-Forwarded-For` entry is the client it accepted the connection
  from (Caddy replaces a client's own header unless told to trust it). A
  request from loopback without one came from the hub machine itself
  (`:local`). Anything else connected directly, so its address is its own.

  Only loopback is trusted to forward: anything else's `X-Forwarded-For`
  is ignored. `client/2` is pure.
  """

  # ::1, and the ::ffff:0:0/96 prefix of IPv4 addresses written as IPv6.
  @ipv6_loopback elem(:inet.parse_address(~c"::1"), 1)
  @mapped_prefix [0, 0, 0, 0, 0, 0xFFFF]

  @doc """
  The client's address, `:local` for the hub machine itself, or nil when a
  proxy forwarded one that can't be read.
  """
  @spec client(:inet.ip_address(), [{String.t(), String.t()}]) ::
          :inet.ip_address() | :local | nil
  def client(remote_ip, headers) do
    if loopback?(remote_ip), do: forwarded(headers), else: ipv4(remote_ip)
  end

  @doc "Who connected: a tailnet device (per `tailscale whois`), `:local`, or `:error`."
  @spec identify(:inet.ip_address(), [{String.t(), String.t()}]) :: Photon.NodeKeys.origin()
  def identify(remote_ip, headers), do: remote_ip |> client(headers) |> whois()

  @doc "Who a client from `client/2` is: a tailnet device, `:local`, or `:error`."
  @spec whois(:inet.ip_address() | :local | nil) :: Photon.NodeKeys.origin()
  def whois(:local), do: :local
  def whois(nil), do: :error
  def whois(ip), do: Photon.Tailnet.whois(ip)

  defp forwarded(headers) do
    case for {"x-forwarded-for", value} <- headers, do: value do
      [] -> :local
      values -> values |> Enum.join(",") |> String.split(",") |> List.last() |> parse()
    end
  end

  defp parse(address) do
    case address |> String.trim() |> String.to_charlist() |> :inet.parse_strict_address() do
      {:ok, ip} -> ipv4(ip)
      {:error, _reason} -> nil
    end
  end

  # An IPv4 address written as IPv6 (::ffff:a.b.c.d) is the IPv4 address,
  # which is how tailscale knows it.
  defp ipv4(ip) when tuple_size(ip) == 8 do
    if ip |> Tuple.to_list() |> Enum.take(6) == @mapped_prefix,
      do: :inet.ipv4_mapped_ipv6_address(ip),
      else: ip
  end

  defp ipv4(ip), do: ip

  defp loopback?({127, _, _, _}), do: true

  defp loopback?(ip) when tuple_size(ip) == 8 do
    ip == @ipv6_loopback or
      (ip |> Tuple.to_list() |> Enum.take(6) == @mapped_prefix and
         ip |> :inet.ipv4_mapped_ipv6_address() |> loopback?())
  end

  defp loopback?(_ip), do: false
end
