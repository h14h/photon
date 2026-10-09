defmodule PhotonNode.Connection do
  @moduledoc """
  The node's websocket link to the hub, as a Phoenix Channels client.

  Reconnects and rejoins with backoff. It carries the operation protocol
  (see `PhotonNode`): the hub's `op.start`, `op.cancel` and `op.ack` are
  parsed with `PhotonCore.Operation.Wire` and handed to
  `PhotonNode.Executor`, and `snapshot/1` and `output/3` implement
  `PhotonNode.Executor.Link`, sending `op.snapshot` and `op.output`. After
  every (re)join it pushes every journaled snapshot
  (`PhotonNode.Executor.snapshots/0`).

  It doesn't catch failures from the executor (node rule 8 in
  `docs/operations.md`): a call that fails crashes this process, the socket
  closes, and the rejoin resends everything. A hub message that doesn't
  parse is logged and ignored, as are unknown events.

  The link callbacks are plain sends to this process, and what arrives
  while the channel isn't joined is dropped, on purpose. A lost snapshot is
  in the executor's journal, which every join sends again. Output is never
  stored, so losing some only thins a stream. Their producers are bounded:
  one snapshot per checkpoint, and shell output sampled once a second in
  chunks of at most 64 KB per stream. A faster producer would need back
  pressure here, since this process pushes everything it is sent.
  """

  # The hub link depends on the executor (it hands it the hub's
  # operations); the executor reaches it only through
  # `PhotonNode.Executor.Link`.
  use Boundary, deps: [PhotonNode, PhotonNode.Config, PhotonNode.Executor, PhotonCore]

  use Slipstream, restart: :permanent

  @behaviour PhotonNode.Executor.Link

  require Logger

  alias PhotonCore.Operation.Wire
  alias PhotonNode.{Config, Executor}

  @op_start Wire.event(:start)
  @op_cancel Wire.event(:cancel)
  @op_ack Wire.event(:ack)

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: Slipstream.start_link(__MODULE__, nil, name: __MODULE__)

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

    {:ok, socket}
  end

  @impl Slipstream
  def handle_connect(socket) do
    Logger.info(
      "photon node #{PhotonNode.config().node_id} connected to #{PhotonNode.config().server}"
    )

    {:ok, join(socket, topic(), hello())}
  end

  @impl Slipstream
  def handle_join(_topic, _reply, socket) do
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

  @impl Slipstream
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

  defp hello do
    config = PhotonNode.config()

    %{
      "hostname" => Config.hostname(),
      "platform" => to_string(:erlang.system_info(:system_architecture)),
      "workspace" => config.workspace,
      "version" => to_string(Application.spec(:photon_node, :vsn)),
      "capabilities" => ["ops:2"]
    }
  end
end
