defmodule PhotonNode.Connection do
  @moduledoc """
  The node's websocket link to the hub, as a Phoenix Channels client.

  Reconnects and rejoins with backoff. It carries two protocols on the one
  channel (see `PhotonNode` for both):

    * sessions: while joined it forwards log records as they are written,
      and after every (re)join it replays whatever the hub is missing, from
      the offsets in the join reply. `event/3` and `live/2` implement
      `PhotonNode.Harness.Link`.
    * operations: the hub's `op.start`, `op.cancel` and `op.ack` are parsed
      with `PhotonCore.Operation.Wire` and handed to `PhotonNode.Executor`,
      and `snapshot/1` and `output/3` implement `PhotonNode.Executor.Link`,
      sending `op.snapshot` and `op.output`. After every (re)join it pushes
      every journaled snapshot (`PhotonNode.Executor.snapshots/0`).

  It doesn't catch failures from the executor (node rule 8 in
  `docs/plans/step-1-machine-tools.md`): a call that fails crashes this
  process, the socket closes, and the rejoin resends everything. A hub
  message that doesn't parse is logged and ignored, as are unknown events.

  The link callbacks are plain sends to this process, and what arrives
  while the channel isn't joined is dropped, on purpose. A lost log record
  costs nothing: the hub notices the gap and asks for a resync, and every
  join replays from the hub's offsets. A lost snapshot is in the
  executor's journal, which every join sends again. Live data is never
  stored, so losing some only thins a stream. Their producers are bounded:
  one record per log append, one snapshot per checkpoint, model deltas from
  at most one request per session, and shell output sampled once a second
  in chunks of at most 64 KB per stream. A faster producer would need back
  pressure here, since this process pushes everything it is sent.
  """

  # The hub link depends on the harness and the executor (it delivers the
  # hub's inputs and operations); they reach it only through
  # `PhotonNode.Harness.Link` and `PhotonNode.Executor.Link`.
  use Boundary,
    deps: [PhotonNode, PhotonNode.Config, PhotonNode.Harness, PhotonNode.Executor, PhotonCore]

  use Slipstream, restart: :permanent

  @behaviour PhotonNode.Harness.Link
  @behaviour PhotonNode.Executor.Link

  require Logger

  alias PhotonCore.Operation.Wire
  alias PhotonNode.{Config, Executor, Harness}

  @op_start Wire.event(:start)
  @op_cancel Wire.event(:cancel)
  @op_ack Wire.event(:ack)

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

  @doc "Sends an operation's latest snapshot to the hub; dropped if the channel isn't joined."
  @impl Executor.Link
  @spec snapshot(PhotonCore.Operation.t()) :: :ok
  def snapshot(op), do: notify({:op_snapshot, op})

  @doc "Streams an operation's new output to the hub, if joined."
  @impl Executor.Link
  @spec output(String.t(), String.t(), String.t()) :: :ok
  def output(op_id, stream, text), do: notify({:op_output, op_id, stream, text})

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

    Enum.each(Executor.snapshots(), &push_op(socket, Wire.snapshot(&1)))
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

  def handle_message(_topic, @op_start, payload, socket),
    do: {:ok, operation(socket, Wire.parse_start(payload), &Executor.start/1)}

  def handle_message(_topic, @op_cancel, payload, socket),
    do: {:ok, operation(socket, Wire.parse_id(payload), &Executor.cancel(&1["id"]))}

  def handle_message(_topic, @op_ack, payload, socket),
    do: {:ok, operation(socket, Wire.parse_id(payload), &Executor.ack(&1["id"]))}

  def handle_message(_topic, event, _payload, socket) do
    Logger.debug("photon node ignoring #{event}")
    {:ok, socket}
  end

  # Hands a parsed hub message to the executor, which must take it: a
  # failed call crashes this process (node rule 8).
  defp operation(socket, {:ok, message}, handle) do
    :ok = handle.(message)
    socket
  end

  defp operation(socket, {:error, reason}, _handle) do
    Logger.warning("photon node ignoring a hub message that doesn't parse: #{reason}")
    socket
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

  def handle_info({:op_snapshot, op}, socket),
    do: {:noreply, forward_op(socket, Wire.snapshot(op), joined?(socket, topic()))}

  def handle_info({:op_output, id, stream, text}, socket),
    do: {:noreply, forward_op(socket, Wire.output(id, stream, text), joined?(socket, topic()))}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp forward_op(socket, _push, false = _joined), do: socket

  defp forward_op(socket, push, true = _joined) do
    :ok = push_op(socket, push)
    socket
  end

  defp push_op(socket, {event, payload}) do
    # A snapshot lost to a dropped socket is in the journal, which the next
    # join sends again, and output is never stored, so the result isn't needed.
    _ = push(socket, topic(), event, payload)
    :ok
  end

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
      "capabilities" => ["harness:1", "ops:1"]
    }
  end
end
