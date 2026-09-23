defmodule PhotonNode.EventLog do
  @moduledoc """
  Append-only per-session event logs. An event's offset is its line index,
  which is what the server uses to deduplicate and detect gaps.

  Appends are serialised through this process so offsets are never reused.
  """

  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Session IDs are file names here, so they are restricted to a safe alphabet."
  def valid_id?(id), do: is_binary(id) and Regex.match?(~r/\A[0-9A-Za-z-]{1,64}\z/, id)

  # IDs are checked in the caller, so a bad one never takes this server down.
  @doc "Appends an event and returns its offset."
  def append(session_id, event),
    do: GenServer.call(__MODULE__, {:append, check!(session_id), event})

  def count(session_id), do: GenServer.call(__MODULE__, {:count, check!(session_id)})

  @doc "Events from `offset` onwards, paired with their offsets."
  def read_from(session_id, offset) do
    path = path(check!(session_id))

    if File.exists?(path) do
      path
      |> File.stream!(:line)
      |> Stream.with_index()
      |> Stream.drop(offset)
      |> Enum.map(fn {line, index} -> {index, Jason.decode!(line)} end)
    else
      []
    end
  end

  def delete(session_id), do: GenServer.call(__MODULE__, {:delete, check!(session_id)})

  defp check!(id) do
    if valid_id?(id), do: id, else: raise(ArgumentError, "invalid session id: #{inspect(id)}")
  end

  @impl true
  def init(_) do
    File.mkdir_p!(PhotonNode.Config.events_dir(PhotonNode.config()))
    {:ok, %{}}
  end

  @impl true
  def handle_call({:append, id, event}, _from, counts) do
    {offset, counts} = cached_count(counts, id)
    File.write!(path(id), [Jason.encode_to_iodata!(event), ?\n], [:append])
    {:reply, offset, Map.put(counts, id, offset + 1)}
  end

  def handle_call({:count, id}, _from, counts) do
    {count, counts} = cached_count(counts, id)
    {:reply, count, counts}
  end

  def handle_call({:delete, id}, _from, counts) do
    File.rm(path(id))
    {:reply, :ok, Map.delete(counts, id)}
  end

  defp cached_count(counts, id) do
    case counts do
      %{^id => n} ->
        {n, counts}

      _ ->
        n =
          if File.exists?(path(id)), do: path(id) |> File.stream!(:line) |> Enum.count(), else: 0

        {n, Map.put(counts, id, n)}
    end
  end

  defp path(id), do: Path.join(PhotonNode.Config.events_dir(PhotonNode.config()), id <> ".jsonl")
end
