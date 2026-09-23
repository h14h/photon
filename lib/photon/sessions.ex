defmodule Photon.Sessions do
  @moduledoc """
  The playground's record of each session: a small metadata file plus every
  event the session's node reported, in order.

  A session lives on one node, which holds the runner's canonical session
  store and its own offset-numbered event log. The server's copy is kept in
  step by offset: `ingest/4` appends only the next expected offset, so
  replays after a reconnect are idempotent and gaps can be re-requested.

  Sessions from before nodes existed are assigned to the `"local"` node, with
  `event_base` recording how many events predate the node's own log.
  """

  alias Photon.Paths

  @topic "sessions"
  @counts :photon_session_event_counts

  @doc "PubSub topic carrying `:sessions_changed`."
  def topic, do: @topic

  def list do
    case File.ls(Paths.sessions_dir()) do
      {:ok, ids} ->
        ids
        |> Enum.map(&get/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1["updated_at"], :desc)

      {:error, _} ->
        []
    end
  end

  def get(id) do
    with true <- valid_id?(id),
         {:ok, body} <- File.read(meta_path(id)),
         {:ok, meta} <- Jason.decode(body) do
      migrate(meta)
    else
      _ -> nil
    end
  end

  defp migrate(%{"node" => _} = meta), do: meta

  defp migrate(meta) do
    meta = Map.merge(meta, %{"node" => "local", "event_base" => line_count(meta["id"])})
    write_meta(meta)
    meta
  end

  def create(title, node_id) do
    id = uuid4()
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    meta = %{
      "id" => id,
      "title" => title,
      "node" => node_id,
      "event_base" => 0,
      "created_at" => now,
      "updated_at" => now
    }

    File.mkdir_p!(dir(id))
    write_meta(meta)
    broadcast()
    meta
  end

  def rename(id, title) do
    if meta = get(id) do
      write_meta(%{meta | "title" => title})
      broadcast()
    end

    :ok
  end

  def touch(id) do
    if meta = get(id) do
      write_meta(%{meta | "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()})
      broadcast()
    end

    :ok
  end

  @doc "Deletes the server's copy. The caller asks the node to delete its own."
  def delete(id) do
    if valid_id?(id) do
      File.rm_rf!(dir(id))
      :ets.delete(@counts, id)
      broadcast()
    end

    :ok
  end

  @doc "Appends decoded events to the session's log, bypassing offset checks."
  def append_events(id, events) do
    File.write!(events_path(id), Enum.map(events, &[Jason.encode_to_iodata!(&1), ?\n]), [:append])
    :ets.delete(@counts, id)
    :ok
  end

  @doc """
  Accepts one event from `node_id` at `offset` in the node's log.

  Returns `:ok` when appended, `:duplicate` for an offset already held,
  `{:gap, expected}` when events are missing, or `:ignored` when the session
  is unknown or belongs to another node.
  """
  def ingest(id, node_id, offset, event) do
    with %{"node" => ^node_id} = meta <- get(id) do
      expected = cursor(meta)

      cond do
        offset == expected ->
          File.write!(events_path(id), [Jason.encode_to_iodata!(event), ?\n], [:append])
          :ets.update_counter(@counts, id, 1)
          Phoenix.PubSub.broadcast(Photon.PubSub, topic(id), {:runner_event, id, event})
          :ok

        offset < expected ->
          :duplicate

        true ->
          {:gap, expected}
      end
    else
      _ -> :ignored
    end
  end

  @doc "PubSub topic carrying `{:runner_event, id, event}` for one session."
  def topic(id), do: "session:" <> id

  @doc "The next node offset expected for each of a node's sessions."
  def sync_for(node_id) do
    for %{"node" => ^node_id} = meta <- list(), into: %{}, do: {meta["id"], cursor(meta)}
  end

  defp cursor(meta), do: line_count(meta["id"]) - Map.get(meta, "event_base", 0)

  @doc false
  def counts_table, do: @counts

  defp line_count(id) do
    case :ets.lookup(@counts, id) do
      [{^id, n}] ->
        n

      [] ->
        n =
          if File.exists?(events_path(id)),
            do: events_path(id) |> File.stream!(:line) |> Enum.count(),
            else: 0

        :ets.insert(@counts, {id, n})
        n
    end
  end

  def events(id) do
    if valid_id?(id) and File.exists?(events_path(id)) do
      events_path(id)
      |> File.stream!()
      |> Stream.map(&String.trim_trailing/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, event} -> [event]
          _ -> []
        end
      end)
    else
      []
    end
  end

  defp write_meta(meta) do
    File.write!(meta_path(meta["id"]), Jason.encode_to_iodata!(meta, pretty: true))
  end

  defp broadcast, do: Phoenix.PubSub.broadcast(Photon.PubSub, @topic, :sessions_changed)

  defp dir(id), do: Path.join(Paths.sessions_dir(), id)
  defp meta_path(id), do: Path.join(dir(id), "meta.json")
  defp events_path(id), do: Path.join(dir(id), "events.jsonl")

  defp valid_id?(id), do: is_binary(id) and Regex.match?(~r/\A[0-9a-f-]{36}\z/, id)

  defp uuid4 do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    <<u0::32, u1::16, u2::16, u3::16, u4::48>> = <<a::48, 4::4, b::12, 2::2, c::62>>

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [u0, u1, u2, u3, u4])
    |> IO.iodata_to_binary()
  end
end

defmodule Photon.Sessions.Counts do
  @moduledoc false
  # Owns the ETS cache of per-session event line counts.
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(Photon.Sessions.counts_table(), [:named_table, :public, :set])
    {:ok, nil}
  end
end
