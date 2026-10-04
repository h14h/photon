defmodule PhotonNode.Harness.Store do
  @moduledoc """
  A session's append-only log: `<sessions dir>/<id>.jsonl`, one record per
  line, owned and written only by the session's coordinator.

  Every record is `{"seq", "at", "kind", "data"}`, where `seq` is the line's
  index. That index is also the record's offset in the stream the hub
  mirrors, so the hub can tell duplicates from gaps. Kinds:

    * `"session"` (always line 0) - `{"version", "id", "created_at", "config"}`
    * `"input"` - `{"id", "kind" ("external" | "control" | "crash"), "payload"}`
    * `"turn"` - `{"id", "previous", "type"}`
    * `"model_response"` - `{"turn_id", "response"}`; the response holds
      `"message"`, `"stop"`, `"usage"`, `"model"`, and `"failure"` when the
      model couldn't be reached
    * `"tool_call_status"` - `{"turn_id", "call_id", "status", "operations"}`;
      the first one for a call carries its new operations, a later one their
      terminal snapshots
    * `"operation"` - an operation checkpoint (full snapshot)
    * `"state"` - `{"state" ("running" | "idle" | "stopped"), ...}`, which
      the hub uses to know when work is done

  Each append is written and synced before it is acted on or announced. A
  torn last line left by a crash is truncated away when the log is reopened.

  Boundary code: the coordinator owns a session's open log (`t/0`) and is
  its only writer; `PhotonNode.Harness` creates and deletes logs, and the
  hub connection reads them to replay.
  """

  alias PhotonNode.Config

  @version 1

  @enforce_keys [:id, :path, :io, :count]
  defstruct [:id, :path, :io, :count]

  @type t :: %__MODULE__{
          id: String.t(),
          path: String.t(),
          io: :file.io_device(),
          count: non_neg_integer()
        }

  @typedoc ~s[A log record: `%{"seq", "at", "kind", "data"}`.]
  @type log_record :: %{String.t() => term()}

  @spec dir() :: String.t()
  def dir, do: Config.sessions_dir(PhotonNode.config())

  @spec path(String.t()) :: String.t()
  def path(id), do: Path.join(dir(), id <> ".jsonl")

  @doc "Where the session's operations keep their files."
  @spec operations_dir(String.t()) :: String.t()
  def operations_dir(id), do: Path.join([dir(), "operations", id])

  @spec exists?(String.t()) :: boolean()
  def exists?(id), do: File.regular?(path(id))

  @doc "Creates a new log with its header record."
  @spec create(String.t(), map()) :: {t(), log_record()}
  def create(id, config) do
    File.mkdir_p!(dir())
    File.chmod!(dir(), 0o700)

    header = %{
      "version" => @version,
      "id" => id,
      "created_at" => now(),
      "config" => config
    }

    record = record(0, "session", header)
    tmp = Path.join(dir(), ".#{id}.#{System.unique_integer([:positive])}.tmp")
    File.write!(tmp, encode(record), [:sync])
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, path(id))
    {:ok, store} = open_append(id, 1)
    {store, record}
  end

  @doc "Opens an existing log for appending; returns the store and every record."
  @spec open(String.t()) :: {:ok, t(), [log_record()]} | {:error, String.t()}
  def open(id) do
    records = read(id)

    case records do
      [%{"kind" => "session", "data" => %{"version" => @version}} | _] ->
        :ok = truncate_torn_tail(path(id))
        {:ok, store} = open_append(id, length(records))
        {:ok, store, records}

      [%{"kind" => "session", "data" => %{"version" => v}} | _] ->
        {:error, "unsupported session log version #{v}"}

      _ ->
        {:error, "session log #{id} has no header"}
    end
  end

  defp open_append(id, count) do
    {:ok, io} = :file.open(path(id), [:append, :binary, :raw])
    {:ok, %__MODULE__{id: id, path: path(id), io: io, count: count}}
  end

  @doc "Appends a record, syncs it, and returns `{store, record}`."
  @spec append(t(), String.t(), map()) :: {t(), log_record()}
  def append(%__MODULE__{} = store, kind, data) do
    record = record(store.count, kind, data)
    :ok = :file.write(store.io, encode(record))
    :ok = :file.datasync(store.io)
    {%{store | count: store.count + 1}, record}
  end

  @spec close(t()) :: :ok
  def close(%__MODULE__{io: io}) do
    # Every append is synced as it's written, so closing has nothing left to
    # flush and its result can go.
    _ = :file.close(io)
    :ok
  end

  @doc "Every complete record in a log (a torn last line is ignored)."
  @spec read(String.t()) :: [log_record()]
  def read(id) do
    case File.read(path(id)) do
      {:ok, body} -> body |> complete_lines() |> Enum.map(&Jason.decode!/1)
      {:error, _} -> []
    end
  end

  @doc "Records from `offset` on, paired with their offsets."
  @spec read_from(String.t(), non_neg_integer()) :: [{non_neg_integer(), log_record()}]
  def read_from(id, offset) do
    id |> read() |> Enum.with_index() |> Enum.drop(offset) |> Enum.map(fn {r, i} -> {i, r} end)
  end

  @doc "Removes a session's log and operation files."
  @spec delete(String.t()) :: :ok | {:error, String.t()}
  def delete(id) do
    with :ok <- remove_log(path(id)),
         {:ok, _removed} <- File.rm_rf(operations_dir(id)) do
      :ok
    else
      {:error, reason, file} ->
        {:error, "couldn't remove #{file}: #{:file.format_error(reason)}"}

      {:error, reason} ->
        {:error, "couldn't remove the log of #{id}: #{:file.format_error(reason)}"}
    end
  end

  defp remove_log(path) do
    case File.rm(path) do
      {:error, :enoent} -> :ok
      result -> result
    end
  end

  @doc "IDs of every session with a log, in name order (oldest first for generated IDs)."
  @spec list() :: [String.t()]
  def list do
    case File.ls(dir()) do
      {:ok, files} ->
        for file <- Enum.sort(files), String.ends_with?(file, ".jsonl"), do: Path.rootname(file)

      {:error, _} ->
        []
    end
  end

  defp complete_lines(body) do
    case :binary.split(body, "\n", [:global]) do
      [] -> []
      parts -> parts |> Enum.drop(-1) |> Enum.reject(&(&1 == ""))
    end
  end

  defp truncate_torn_tail(path) do
    body = File.read!(path)

    case :binary.matches(body, "\n") do
      [] ->
        :ok

      matches ->
        {pos, 1} = List.last(matches)

        if pos + 1 < byte_size(body) do
          {:ok, io} = :file.open(path, [:read, :write, :binary, :raw])
          {:ok, _} = :file.position(io, pos + 1)
          :ok = :file.truncate(io)
          :ok = :file.close(io)
        else
          :ok
        end
    end
  end

  defp record(seq, kind, data), do: %{"seq" => seq, "at" => now(), "kind" => kind, "data" => data}

  defp encode(record), do: [Jason.encode_to_iodata!(record), ?\n]

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
