defmodule PhotonWeb.NodeSocket do
  @moduledoc "Websocket that agent nodes connect to, authenticated by `Photon.NodeAuth`."

  use Phoenix.Socket

  channel "node:*", PhotonWeb.NodeChannel

  @impl true
  def connect(_params, socket, %{x_headers: headers}) do
    case List.keyfind(headers, "x-photon-token", 0) do
      {_, token} -> if Photon.NodeAuth.valid?(token), do: {:ok, socket}, else: :error
      nil -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(_socket), do: nil
end
