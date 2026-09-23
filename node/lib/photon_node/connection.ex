defmodule PhotonNode.Connection do
  @moduledoc """
  The node's websocket link to the Photon server, as a Phoenix Channels client.

  Reconnects and rejoins with backoff. While joined it forwards run events as
  they happen; after every (re)join it replays whatever the server is missing,
  starting from the offsets in the join reply. See `PhotonNode` for the
  protocol.
  """

  use Slipstream, restart: :permanent

  require Logger

  alias PhotonNode.{Config, EventLog, Run, Runner}

  def start_link(_opts), do: Slipstream.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Delivers a run notification; dropped if the connection process is down."
  def notify(message) do
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

    # `sent` tracks, per session, the next offset the server should receive.
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

    push(socket, topic(), "status", %{"running" => Runner.running_ids()})
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

  def handle_message(_topic, "start_run", %{"session_id" => id} = payload, socket) do
    attachments = List.wrap(payload["attachments"])

    case Runner.start(id, payload["prompt"] || "", payload["config"] || %{}, attachments) do
      {:ok, _pid} ->
        {:ok, socket}

      {:error, reason} ->
        # Recorded like any other event, so the failure shows in the transcript.
        if EventLog.valid_id?(id), do: Run.record(id, %{"type" => "error", "message" => reason})
        push(socket, topic(), "run_finished", %{"session_id" => id, "status" => nil})
        {:ok, socket}
    end
  end

  def handle_message(_topic, "stop_run", %{"session_id" => id}, socket) do
    Runner.stop(id)
    {:ok, socket}
  end

  def handle_message(_topic, "delete_session", %{"session_id" => id}, socket) do
    Runner.delete(id)
    {:ok, update(socket, :sent, &Map.delete(&1, id))}
  end

  def handle_message(_topic, "resync", %{"session_id" => id, "from" => from}, socket)
      when is_integer(from) and from >= 0 do
    if EventLog.valid_id?(id), do: {:ok, replay(socket, id, from)}, else: {:ok, socket}
  end

  def handle_message(_topic, event, _payload, socket) do
    Logger.debug("photon node ignoring #{event}")
    {:ok, socket}
  end

  # Replays can overtake live notifications still in the mailbox, so anything
  # below the watermark is a duplicate, and anything above it means a gap. A
  # session missing from `sent` (new since the join) starts at this offset.
  @impl Slipstream
  def handle_info({:event, id, offset, event}, socket) do
    cond do
      not joined?(socket, topic()) ->
        {:noreply, socket}

      offset < Map.get(socket.assigns.sent, id, offset) ->
        {:noreply, socket}

      offset == Map.get(socket.assigns.sent, id, offset) ->
        push(socket, topic(), "event", %{"session_id" => id, "offset" => offset, "event" => event})

        {:noreply, update(socket, :sent, &Map.put(&1, id, offset + 1))}

      true ->
        {:noreply, replay(socket, id, socket.assigns.sent[id])}
    end
  end

  def handle_info({:run_started, id}, socket) do
    if joined?(socket, topic()), do: push(socket, topic(), "run_started", %{"session_id" => id})
    {:noreply, socket}
  end

  def handle_info({:run_finished, id, status}, socket) do
    if joined?(socket, topic()),
      do: push(socket, topic(), "run_finished", %{"session_id" => id, "status" => status})

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp replay(socket, id, from) do
    events = EventLog.read_from(id, from)

    for {offset, event} <- events do
      push(socket, topic(), "event", %{"session_id" => id, "offset" => offset, "event" => event})
    end

    next =
      if events == [], do: max(from, EventLog.count(id)), else: elem(List.last(events), 0) + 1

    update(socket, :sent, &Map.put(&1, id, next))
  end

  defp hello do
    config = PhotonNode.config()

    %{
      "hostname" => Config.hostname(),
      "platform" => to_string(:erlang.system_info(:system_architecture)),
      "runner" => Runner.executable(config),
      "workspace" => config.workspace,
      "key_envs" => Runner.key_envs(),
      "version" => to_string(Application.spec(:photon_node, :vsn)),
      # Features the hub may rely on; older nodes send none.
      "capabilities" => ["attachments"]
    }
  end
end
