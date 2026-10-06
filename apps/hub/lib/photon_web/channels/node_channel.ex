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

  Operations (section 2 of `docs/plans/step-1-machine-tools.md`) go to
  `Photon.Machines`, and the channel pushes what it returns: `op.snapshot`
  answers with `op.ack` or `op.cancel` once the snapshot is recorded,
  `op.output` is broadcast to the tool call's conversation, and a join
  pushes `op.start` or `op.cancel` for every open op of the node. An
  `op.start` is only ever built here, from the op's row as it is when it is
  pushed: `{:push_op, op_id}` (from `Photon.Nodes.push_op/2`) asks for one,
  and a `{:command, "op.start", _}` is dropped with a log line, so an
  `op.start` decided elsewhere, before a result was recorded, can't reach a
  node that has just forgotten the op. Failures from `Photon.Machines` are
  not caught: the channel crashes, the node reconnects, and the join
  resends everything.

  The channel caches where each op's live output goes (`routes`, see
  `Photon.Machines.output/3`), and drops an op from it with the op's
  terminal snapshot.

  Two things happen in the process on purpose. A node that reconnects
  before its old connection timed out takes over in `join/3`: registering
  waits up to two seconds for the old process to go (then kills it), so a
  node never has two connections. And it remembers which inputs it pushed
  on this connection: an input goes to the node at most once per
  connection.
  """

  use Phoenix.Channel

  require Logger

  alias Photon.{Machines, NodeKeys, Nodes, NodeSessions}
  alias PhotonCore.Operation.Wire

  @op_start Wire.event(:start)
  @op_snapshot Wire.event(:snapshot)
  @op_output Wire.event(:output)

  # A node joins as the node its key belongs to (`PhotonWeb.NodeSocket`),
  # while that key is still current. It listens for key changes before it
  # checks (so none slips in between), and checks again once registered,
  # which can wait on a previous connection; afterwards it goes, closing
  # the connection, as soon as its own key is no longer current.
  @impl true
  def join("node:" <> node_id, info, %{assigns: %{node_id: node_id}} = socket) do
    :ok = NodeKeys.subscribe()
    current? = fn -> NodeKeys.current?(node_id, socket.assigns.generation) end

    with true <- current?.(),
         :ok <- Nodes.register(node_id, node_info(info)),
         true <- still_current(current?, node_id) do
      send(self(), :joined)

      {:ok, %{"sync" => NodeSessions.sync_for(node_id)},
       assign(socket, pushed_inputs: MapSet.new(), sessions: MapSet.new(), routes: %{})}
    else
      _replaced -> {:error, %{"reason" => "this key has been replaced"}}
    end
  end

  def join("node:" <> other, _info, socket),
    do: {:error, %{"reason" => "this key belongs to #{socket.assigns.node_id}, not #{other}"}}

  # If the key was replaced meanwhile, gives up the registration it just took.
  defp still_current(current?, node_id) do
    current?.() or Nodes.unregister(node_id) != :ok
  end

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

  # Live output streams often, so which sessions are this node's is
  # remembered once looked up.
  def handle_in("live", %{"session_id" => id, "data" => data}, socket) do
    cond do
      MapSet.member?(socket.assigns.sessions, id) ->
        NodeSessions.live(id, data)
        {:noreply, socket}

      NodeSessions.owned?(id, socket.assigns.node_id) ->
        NodeSessions.live(id, data)
        {:noreply, assign(socket, :sessions, MapSet.put(socket.assigns.sessions, id))}

      true ->
        {:noreply, socket}
    end
  end

  def handle_in(
        "input_rejected",
        %{"session_id" => id, "input_id" => input_id, "reason" => reason},
        socket
      ) do
    NodeSessions.reject_input(id, input_id, reason, socket.assigns.node_id)
    {:noreply, socket}
  end

  def handle_in(@op_snapshot, payload, socket) do
    {pushes, routes} = Machines.snapshot(socket.assigns.node_id, payload, socket.assigns.routes)
    {:noreply, socket |> push_all(pushes) |> assign(:routes, routes)}
  end

  def handle_in(@op_output, payload, socket) do
    routes = Machines.output(socket.assigns.node_id, payload, socket.assigns.routes)
    {:noreply, assign(socket, :routes, routes)}
  end

  def handle_in(event, _payload, socket) do
    Logger.debug("node #{socket.assigns.node_id} sent unknown event #{event}")
    {:noreply, socket}
  end

  @impl true
  def handle_info(:joined, socket) do
    Nodes.broadcast()
    NodeSessions.resend_queued(socket.assigns.node_id)
    {:noreply, push_all(socket, Machines.joined(socket.assigns.node_id))}
  end

  def handle_info({:push_op, op_id}, socket),
    do: {:noreply, push_all(socket, Machines.push_for(socket.assigns.node_id, op_id))}

  # Only `{:push_op, id}` puts an `op.start` on the wire; see the moduledoc.
  def handle_info({:command, @op_start, %{} = payload}, socket) do
    Logger.warning("dropped an op.start for #{payload["id"]} that wasn't built by the channel")
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

  def handle_info({:node_keys_changed, node_id}, %{assigns: %{node_id: node_id}} = socket) do
    if NodeKeys.current?(node_id, socket.assigns.generation) do
      {:noreply, socket}
    else
      # Closes the websocket itself, not only this channel, so the old key
      # can't join again over it.
      :ok = socket.endpoint.broadcast(socket.id, "disconnect", %{})
      {:stop, {:shutdown, :key_replaced}, socket}
    end
  end

  def handle_info({:node_keys_changed, _other}, socket), do: {:noreply, socket}

  defp push_all(socket, pushes) do
    Enum.each(pushes, fn {event, payload} -> push(socket, event, payload) end)
    socket
  end

  @impl true
  def terminate(_reason, socket) do
    if node_id = socket.assigns[:node_id] do
      Nodes.unregister(node_id)
      Nodes.broadcast()
    end

    :ok
  end
end
