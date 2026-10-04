defmodule PhotonWeb.NodeSocket do
  @moduledoc """
  Websocket that agent nodes connect to. A node presents its own key
  (header `x-photon-token`), which `Photon.NodeKeys` checks against where
  the connection came from (`PhotonWeb.ClientIP`); the socket then knows
  which node it is (`:node_id`), and `PhotonWeb.NodeChannel` lets it join
  as that node only.
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
         {:ok, node_id} <- Photon.NodeKeys.authenticate(token, origin) do
      {:ok, assign(socket, :node_id, node_id)}
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
  def id(_socket), do: nil
end
