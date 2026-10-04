defmodule PhotonNode.Connection do
  @moduledoc """
  The node's websocket link to the hub, as a Phoenix Channels client.

  Reconnects and rejoins with backoff. While joined it forwards log records
  as they are written; after every (re)join it replays whatever the hub is
  missing, from the offsets in the join reply. See `PhotonNode` for the
  protocol.

  It is the harness's hub link: `event/3` and `live/2` implement
  `PhotonNode.Harness.Link`. They are plain sends, dropped while the
  connection is down, on purpose. A lost log record costs nothing: the hub notices the
  gap and asks for a resync, and every join replays from the hub's offsets.
  Live data is never stored, so losing some only thins a stream. Their
  producers are bounded: one record per log append, model deltas from at
  most one request per session, and shell output sampled once a second in
  chunks of at most 64 KB per stream. A faster producer would need back pressure here,
  since this process pushes everything it is sent.
  """

  # The hub link depends on the harness (it delivers the hub's inputs);
  # the harness reaches it only through `PhotonNode.Harness.Link`.
  use Boundary, deps: [PhotonNode, PhotonNode.Config, PhotonNode.Harness, PhotonCore]

  use Slipstream, restart: :permanent

  @behaviour PhotonNode.Harness.Link

  require Logger

  alias PhotonNode.{Config, Harness}

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: Slipstream.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Announces a session's log record at `offset`; dropped if the connection is down."
  @impl Harness.Link
  @spec event(String.t(), non_neg_integer(), map()) :: :ok
  def event(session_id, offset, record), do: notify({:event, session_id, offset, record})

  @doc "Streams ephemeral data for a session to the hub, if connected."
  @impl Harness.Link
  @spec live(String.t(), map()) :: :ok
  def live(session_id, data), do: notify({:live, session_id, data})

  defp notify(message) do
    if pid = Process.whereis(__MODULE__), do: send(pid, message)
    :ok
  end

  defp topic, do: "node:" <> PhotonNode.config().node_id

  @impl Slipstream
  def init(_) do
    config = PhotonNode.config()

    socket =
      connect!(
        uri: config.server,
        headers: [{"x-photon-token", config.token}],
        reconnect_after_msec: [500, 1_000, 2_000, 5_000, 10_000]
      )

    # `sent` tracks, per session, the next offset the hub should receive.
    {:ok, assign(socket, sent: %{})}
  end

  @impl Slipstream
  def handle_connect(socket) do
    Logger.info(
      "photon node #{PhotonNode.config().node_id} connected to #{PhotonNode.config().server}"
    )

    {:ok, join(socket, topic(), hello())}
  end

  @impl Slipstream
  def handle_join(_topic, %{"sync" => sync}, socket) do
    socket =
      Enum.reduce(sync, assign(socket, sent: %{}), fn {id, from}, socket ->
        replay(socket, id, from)
      end)

    {:ok, socket}
  end

  @impl Slipstream
  def handle_topic_close(topic, reason, socket) do
    Logger.warning("photon node left #{topic}: #{inspect(reason)}; rejoining")
    rejoin(socket, topic, hello())
  end

  @impl Slipstream
  def handle_disconnect(reason, socket) do
    Logger.warning("photon node disconnected: #{inspect(reason)}; reconnecting")
    reconnect(socket)
  end

  @impl Slipstream
  def handle_message(_topic, event, %{"session_id" => id}, socket)
      when not is_binary(id) or byte_size(id) > 64 do
    Logger.warning("photon node ignoring #{event} with an invalid session id")
    {:ok, socket}
  end

  def handle_message(_topic, "input", %{"session_id" => id, "input" => input} = payload, socket) do
    case Harness.deliver(id, input, payload["config"]) do
      :ok -> :ok
      {:error, reason} -> reject_input(socket, id, input, reason)
    end

    {:ok, socket}
  end

  def handle_message(_topic, "stop", %{"session_id" => id}, socket) do
    Harness.stop(id)
    {:ok, socket}
  end

  def handle_message(_topic, "delete_session", %{"session_id" => id}, socket) do
    case Harness.delete(id) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("photon node couldn't delete session #{id}: #{reason}")
    end

    {:ok, update(socket, :sent, &Map.delete(&1, id))}
  end

  def handle_message(_topic, "resync", %{"session_id" => id, "from" => from}, socket)
      when is_integer(from) and from >= 0 do
    if PhotonCore.ID.valid?(id), do: {:ok, replay(socket, id, from)}, else: {:ok, socket}
  end

  def handle_message(_topic, event, _payload, socket) do
    Logger.debug("photon node ignoring #{event}")
    {:ok, socket}
  end

  defp reject_input(socket, id, input, reason) do
    Logger.warning("photon node couldn't deliver input to #{id}: #{reason}")
    message = %{"session_id" => id, "input_id" => input["id"], "reason" => reason}

    # If the socket drops before this goes out, the hub resends the input on
    # the next join and the node refuses it again, so nothing is lost.
    _ = push(socket, topic(), "input_rejected", message)
    :ok
  end

  @impl Slipstream
  def handle_info({:event, id, offset, event}, socket),
    do: {:noreply, forward(socket, id, offset, event, joined?(socket, topic()))}

  def handle_info({:live, id, data}, socket) do
    if joined?(socket, topic()),
      do: push(socket, topic(), "live", %{"session_id" => id, "data" => data})

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp forward(socket, _id, _offset, _event, false = _joined), do: socket

  defp forward(socket, id, offset, event, true = _joined),
    do: forward_at(socket, id, offset, event, Map.get(socket.assigns.sent, id, offset))

  # Replays can overtake live notifications still in the mailbox, so anything
  # below the watermark is a duplicate, and anything above it means a gap. A
  # session missing from `sent` (new since the join) starts at this offset.
  defp forward_at(socket, _id, offset, _event, next) when offset < next, do: socket

  defp forward_at(socket, id, offset, event, offset) do
    :ok = push_record(socket, id, offset, event)
    update(socket, :sent, &Map.put(&1, id, offset + 1))
  end

  defp forward_at(socket, id, _offset, _event, next), do: replay(socket, id, next)

  # The watermark comes from the same read as the records pushed: a record
  # appended after that read is announced by its own notification, which
  # must then count as new, not as a duplicate.
  defp replay(socket, id, from) do
    records = Harness.records_from(id, from)

    Enum.each(records, fn {offset, record} -> push_record(socket, id, offset, record) end)
    update(socket, :sent, &Map.put(&1, id, from + length(records)))
  end

  defp push_record(socket, id, offset, record) do
    payload = %{"session_id" => id, "offset" => offset, "event" => record}

    # A push lost to a dropped socket is replayed from the hub's sync offsets
    # on the next join, so this one's result isn't needed.
    _ = push(socket, topic(), "event", payload)
    :ok
  end

  defp hello do
    config = PhotonNode.config()

    %{
      "hostname" => Config.hostname(),
      "platform" => to_string(:erlang.system_info(:system_architecture)),
      "workspace" => config.workspace,
      "version" => to_string(Application.spec(:photon_node, :vsn)),
      "capabilities" => ["harness:1"]
    }
  end
end
