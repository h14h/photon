defmodule PhotonWeb.NodeChannel do
  @moduledoc """
  The hub's end of one node's connection. See `PhotonNode` for the protocol.
  The channel process registers itself as the node's connection
  (`Photon.Nodes.register/2`), so a node is online exactly as long as this
  process lives.

  It is the server layer for a node (Phoenix starts one per connection), so
  it holds no logic of its own: records, refusals and live output go to
  `Photon.NodeSessions`, and commands arrive from `Photon.Nodes.command/3`
  as `{:command, event, payload}` messages and are pushed as they come.
  Events it doesn't know are logged and ignored, so either side can deploy
  first.

  Two things happen in the process on purpose. A node that reconnects
  before its old connection timed out takes over in `join/3`: registering
  waits up to two seconds for the old process to go (then kills it), so a
  node never has two connections. And it remembers which inputs it pushed
  on this connection: an input goes to the node at most once per
  connection.
  """

  use Phoenix.Channel

  require Logger

  alias Photon.{Nodes, NodeSessions}

  # A node joins as the node its key belongs to (`PhotonWeb.NodeSocket`).
  @impl true
  def join("node:" <> node_id, info, %{assigns: %{node_id: node_id}} = socket) do
    :ok = Nodes.register(node_id, node_info(info))
    send(self(), :joined)

    {:ok, %{"sync" => NodeSessions.sync_for(node_id)},
     assign(socket, :pushed_inputs, MapSet.new())}
  end

  def join("node:" <> other, _info, socket),
    do: {:error, %{"reason" => "this key belongs to #{socket.assigns.node_id}, not #{other}"}}

  defp node_info(info) do
    info
    |> Map.take(~w(hostname platform workspace version capabilities))
    |> Map.put("connected_at", DateTime.utc_now())
  end

  @impl true
  def handle_in("event", %{"session_id" => id, "offset" => offset, "event" => event}, socket) do
    case NodeSessions.ingest(id, socket.assigns.node_id, offset, event) do
      {:gap, from} -> push(socket, "resync", %{"session_id" => id, "from" => from})
      _ -> :ok
    end

    {:noreply, socket}
  end

  def handle_in("live", %{"session_id" => id, "data" => data}, socket) do
    NodeSessions.live(id, data)
    {:noreply, socket}
  end

  def handle_in(
        "input_rejected",
        %{"session_id" => id, "input_id" => input_id, "reason" => reason},
        socket
      ) do
    NodeSessions.reject_input(id, input_id, reason)
    {:noreply, socket}
  end

  def handle_in(event, _payload, socket) do
    Logger.debug("node #{socket.assigns.node_id} sent unknown event #{event}")
    {:noreply, socket}
  end

  @impl true
  def handle_info(:joined, socket) do
    Nodes.broadcast()
    NodeSessions.resend_queued(socket.assigns.node_id)
    {:noreply, socket}
  end

  # An input goes to the node at most once per connection: the node answers
  # every delivery for good (accepted, a repeat, or refused), so a second
  # copy (a send racing the resend at join) could only undo a refusal.
  def handle_info({:command, "input", %{"input" => %{"id" => input_id}} = payload}, socket) do
    if MapSet.member?(socket.assigns.pushed_inputs, input_id) do
      {:noreply, socket}
    else
      push(socket, "input", payload)

      {:noreply,
       assign(socket, :pushed_inputs, MapSet.put(socket.assigns.pushed_inputs, input_id))}
    end
  end

  def handle_info({:command, event, payload}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  def handle_info(:replaced, socket), do: {:stop, {:shutdown, :replaced}, socket}

  @impl true
  def terminate(_reason, socket) do
    if node_id = socket.assigns[:node_id] do
      Nodes.unregister(node_id)
      Nodes.broadcast()
    end

    :ok
  end
end
