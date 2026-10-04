defmodule Photon.InstallScript do
  @moduledoc """
  The node install script (`priv/node/install.sh.eex`) and the websocket
  URL it points nodes at, as pure functions of the hub's base URL.
  `Photon.NodeDist` serves the script, `Photon.Provision` sends it over
  SSH, and `Photon.Hub` tells the UI the same URL.
  """

  use Boundary, type: :strict, deps: [EEx]

  @template Path.expand("../../priv/node/install.sh.eex", __DIR__)
  @external_resource @template
  require EEx
  EEx.function_from_file(:defp, :render_script, @template, [:assigns])

  @doc "The install script, pointing at the hub's base URL."
  @spec render(String.t()) :: String.t()
  def render(base_url) do
    render_script(%{
      hub_http: sh_safe!(base_url),
      server_url: base_url |> socket_url() |> sh_safe!()
    })
  end

  @doc "The websocket URL a node connects to, given the hub's base URL."
  @spec socket_url(String.t()) :: String.t()
  def socket_url(base) do
    base
    |> String.replace_prefix("https://", "wss://")
    |> String.replace_prefix("http://", "ws://")
    |> Kernel.<>("/node/websocket")
  end

  # URLs are interpolated into single-quoted and double-quoted shell strings.
  defp sh_safe!(value) do
    if value =~ ~r/\A[A-Za-z0-9:\/._\-\[\]%]+\z/,
      do: value,
      else: raise(ArgumentError, "unexpected characters in hub URL #{inspect(value)}")
  end
end
