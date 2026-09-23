defmodule PhotonWeb.NodeChannel do
  @moduledoc """
  The server's end of one agent node's connection. See `PhotonNode` for the
  protocol. The channel process registers itself in `Photon.NodeRegistry`, so
  a node is online exactly as long as this process lives.
  """

  use Phoenix.Channel

  require Logger

  alias Photon.{Nodes, Sessions}

  @impl true
  def join("node:" <> node_id, info, socket) do
    if Regex.match?(~r/\A[\w.-]{1,64}\z/, node_id) do
      replace_existing(node_id)
      {:ok, _} = Registry.register(Photon.NodeRegistry, node_id, node_info(info))
      send(self(), :joined)
      {:ok, %{"sync" => Sessions.sync_for(node_id)}, assign(socket, :node_id, node_id)}
    else
      {:error, %{"reason" => "invalid node id"}}
    end
  end

  # A node that reconnects before its old connection timed out takes over.
  defp replace_existing(node_id) do
    case Registry.lookup(Photon.NodeRegistry, node_id) do
      [{pid, _}] ->
        Logger.warning("node #{node_id} reconnected; closing its previous connection")
        ref = Process.monitor(pid)
        send(pid, :replaced)

        receive do
          {:DOWN, ^ref, _, _, _} -> :ok
        after
          2_000 -> Process.exit(pid, :kill)
        end

      [] ->
        :ok
    end
  end

  defp node_info(info) do
    info
    |> Map.take(~w(hostname platform runner workspace key_envs version capabilities))
    |> Map.merge(%{"running" => MapSet.new(), "connected_at" => DateTime.utc_now()})
  end

  @impl true
  def handle_in("event", %{"session_id" => id, "offset" => offset, "event" => event}, socket) do
    case Sessions.ingest(id, socket.assigns.node_id, offset, event) do
      {:gap, from} -> push(socket, "resync", %{"session_id" => id, "from" => from})
      _ -> :ok
    end

    {:noreply, socket}
  end

  def handle_in("run_started", %{"session_id" => id}, socket) do
    update_running(socket, &MapSet.put(&1, id))
    {:noreply, socket}
  end

  def handle_in("run_finished", %{"session_id" => id}, socket) do
    update_running(socket, &MapSet.delete(&1, id))
    Sessions.touch(id)
    {:noreply, socket}
  end

  def handle_in("status", %{"running" => running}, socket) do
    update_running(socket, fn _ -> MapSet.new(running) end)
    {:noreply, socket}
  end

  def handle_in(event, _payload, socket) do
    Logger.debug("node #{socket.assigns.node_id} sent unknown event #{event}")
    {:noreply, socket}
  end

  @impl true
  def handle_info(:joined, socket) do
    Nodes.broadcast()
    {:noreply, socket}
  end

  def handle_info({:command, event, payload}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  def handle_info(:replaced, socket), do: {:stop, {:shutdown, :replaced}, socket}

  @impl true
  def terminate(_reason, socket) do
    if node_id = socket.assigns[:node_id] do
      Registry.unregister(Photon.NodeRegistry, node_id)
      Nodes.broadcast()
    end

    :ok
  end

  defp update_running(socket, fun) do
    Registry.update_value(
      Photon.NodeRegistry,
      socket.assigns.node_id,
      &Map.update!(&1, "running", fun)
    )

    Nodes.broadcast()
  end
end
