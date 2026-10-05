defmodule PhotonWeb.NodeSocket do
  @moduledoc """
  Websocket that agent nodes connect to. A node presents its own key
  (header `x-photon-token`), which `Photon.NodeKeys` checks against where
  the connection came from (`PhotonWeb.ClientIP`), requiring a tailnet
  device when the hub vouches for devices through its tailnet. The socket
  then knows which node it is (`:node_id`) and which of its keys it used
  (`:generation`), and `PhotonWeb.NodeChannel` lets it join as that node
  only, while that key is current. Its ID names both, so the channel can
  close the connection when the key is replaced.
  """

  use Phoenix.Socket

  require Logger

  alias PhotonWeb.ClientIP

  channel "node:*", PhotonWeb.NodeChannel

  @impl true
  def connect(_params, socket, %{x_headers: headers} = connect_info) do
    # Without the peer's address, nothing can say where the key came from.
    origin =
      case connect_info do
        %{peer_data: %{address: address}} -> ClientIP.identify(address, headers)
        _no_peer -> :error
      end

    with {_, token} <- List.keyfind(headers, "x-photon-token", 0),
         {:ok, node_id, generation} <-
           Photon.NodeKeys.authenticate(token, origin, Photon.Auth.node_key_policy()) do
      {:ok, socket |> assign(:node_id, node_id) |> assign(:generation, generation)}
    else
      nil -> refuse("no node key")
      {:error, reason} -> refuse(reason)
    end
  end

  def connect(_params, _socket, _connect_info), do: refuse("no node key")

  defp refuse(reason) do
    Logger.warning("refused a node connection: #{reason}")
    :error
  end

  @impl true
  def id(socket), do: "node_socket:#{socket.assigns.node_id}:#{socket.assigns.generation}"
end
