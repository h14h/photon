defmodule PhotonNode.Executor.Journal do
  @moduledoc """
  The node's durable record of the hub's operations
  (`docs/plans/step-1-machine-tools.md`, section 2.3, node rules 1 and 5
  to 8): one file per operation, `<ops dir>/<op_id>/op.json`, next to the
  shell's `out`, `err`, `pid`, `exit`, `stopped` and `unstarted` files.

  Each file holds an entry, `%{"op" => snapshot, "cancel" => boolean}`: the
  operation's latest snapshot and whether the hub has canceled it. `write/3`
  replaces it whole or not at all. The entry goes to `op.json.tmp`, mode
  0600, which is synced and renamed over `op.json`, and then the directory
  is synced so the rename survives a power loss. A crash at any point leaves
  either the old entry or the new one, never a torn file, so `read/2`
  returns the last entry that was fully written. A leftover `op.json.tmp`
  is overwritten by the next write and otherwise ignored.

  `write/3` returns `{:error, reason}` only when the new entry isn't in
  place: once the rename has happened the entry is the new one, so a
  failed directory sync is logged rather than returned. The executor
  relies on this: an error means nothing changed (node rule 8).

  `discard/2` deletes the entry alone, for a `ready` entry that a result
  the executor couldn't journal has left behind (node rule 8).

  After `op.ack`, `forget/2` deletes the entry and the files only a running
  command needs. `out` and `err` stay, since a truncated result names
  them, until `sweep/3` removes directories without an entry that are
  older than its age limit (node rule 6).

  Boundary helper for `PhotonNode.Executor`: file I/O, no process. Only the
  executor process calls it, so writes to one operation's entry never race.
  Operation IDs come from `PhotonCore.Operation.Wire`, which lets through
  only IDs that are safe as directory names.
  """

  require Logger

  @entry "op.json"
  @tmp "op.json.tmp"

  # Files `forget/2` deletes; `out` and `err` stay for the sweep.
  @forgotten [@entry, @tmp, "pid", "exit", "stopped", "unstarted"]

  @typedoc ~S|A journal entry: `%{"op" => snapshot, "cancel" => boolean}`.|
  @type entry :: %{required(String.t()) => term()}

  @doc "Where an operation keeps its entry and files: `<ops_dir>/<id>`."
  @spec op_dir(String.t(), String.t()) :: String.t()
  def op_dir(ops_dir, id), do: Path.join(ops_dir, id)

  @doc """
  The operation's entry, or `{:ok, nil}` if it has none. An entry that
  can't be read or isn't one is `{:error, reason}`.
  """
  @spec read(String.t(), String.t()) :: {:ok, entry() | nil} | {:error, String.t()}
  def read(ops_dir, id) do
    path = Path.join(op_dir(ops_dir, id), @entry)

    with {:ok, body} <- read_file(path),
         {:ok, data} <- decode(body, path) do
      validate(data, id, path)
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, :enoent} -> {:ok, nil}
      {:error, reason} -> {:error, "can't read #{path} (#{:file.format_error(reason)})"}
    end
  end

  defp decode(nil, _path), do: {:ok, nil}

  defp decode(body, path) do
    case Jason.decode(body) do
      {:ok, data} -> {:ok, data}
      {:error, _} -> {:error, "#{path} isn't valid JSON"}
    end
  end

  defp validate(nil, _id, _path), do: {:ok, nil}

  defp validate(%{"op" => %{"id" => id}, "cancel" => cancel} = entry, id, _path)
       when is_boolean(cancel),
       do: {:ok, entry}

  defp validate(_data, id, path), do: {:error, "#{path} isn't a journal entry for #{id}"}

  @doc """
  Replaces the operation's entry with `entry`, creating its directory, and
  returns once the entry is on disk. `{:error, reason}` means the old entry
  (or none) is still in place.
  """
  @spec write(String.t(), String.t(), entry()) :: :ok | {:error, String.t()}
  def write(ops_dir, id, %{"op" => %{"id" => id}, "cancel" => cancel} = entry)
      when is_boolean(cancel) do
    dir = op_dir(ops_dir, id)
    created? = not File.dir?(dir)

    with {:ok, data} <- encode(entry),
         :ok <- ensure_dir(dir),
         :ok <- write_synced(Path.join(dir, @tmp), data),
         :ok <- rename(Path.join(dir, @tmp), Path.join(dir, @entry)) do
      # A new directory's own name is in the ops directory, so that is
      # synced too.
      sync_dirs(if created?, do: [dir, ops_dir], else: [dir])
    end
  end

  defp encode(entry) do
    case Jason.encode_to_iodata(entry) do
      {:ok, data} -> {:ok, data}
      {:error, error} -> {:error, "can't encode the journal entry (#{Exception.message(error)})"}
    end
  end

  defp ensure_dir(dir) do
    with {:error, reason} <- mkdir(dir), do: file_error("create", dir, reason)
  end

  # Command output can hold secrets, so only this user may look inside.
  defp mkdir(dir) do
    with :ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)
  end

  # Created empty and narrowed to mode 0600 before any data goes in, as
  # `Photon.PrivateFile` does on the hub.
  defp write_synced(path, data) do
    with {:error, reason} <- create_synced(path, data), do: file_error("write", path, reason)
  end

  defp create_synced(path, data) do
    with :ok <- File.write(path, ""),
         :ok <- File.chmod(path, 0o600),
         {:ok, io} <- :file.open(path, [:write, :binary, :raw]) do
      result = write_and_sync(io, data)
      # The data is synced (or the write already failed and says so), so
      # the close has nothing left to report.
      _ = :file.close(io)
      result
    end
  end

  defp write_and_sync(io, data) do
    with :ok <- :file.write(io, data), do: :file.sync(io)
  end

  defp rename(from, to) do
    with {:error, reason} <- File.rename(from, to), do: file_error("rename", from, reason)
  end

  # Erlang can't open a directory to fsync it, so this runs `sync` on it,
  # which coreutils' and busybox's versions do for each path they are
  # given. Elsewhere (macOS's `sync` takes no paths and flushes every
  # disk) the rename is left to the file system. The entry is already in
  # place, so a failure here is only logged.
  defp sync_dirs(dirs) do
    case sync_command() do
      nil -> :ok
      sync -> run_sync(sync, dirs)
    end
  end

  defp sync_command do
    case :os.type() do
      {:unix, :linux} -> System.find_executable("sync")
      _ -> nil
    end
  end

  defp run_sync(sync, dirs) do
    case System.cmd(sync, ["--" | dirs], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        Logger.warning("couldn't sync #{Enum.join(dirs, ", ")} (exit #{status}): #{output}")
        :ok
    end
  end

  @doc """
  Every readable entry under `ops_dir`, in ID order. An entry that can't be
  read is logged and left out.
  """
  @spec list(String.t()) :: [entry()]
  def list(ops_dir) do
    for id <- op_ids(ops_dir), entry = listed(ops_dir, id), entry != nil, do: entry
  end

  defp listed(ops_dir, id) do
    case read(ops_dir, id) do
      {:ok, entry} ->
        entry

      {:error, reason} ->
        Logger.warning("skipping an unreadable journal entry: #{reason}")
        nil
    end
  end

  defp op_ids(ops_dir) do
    case File.ls(ops_dir) do
      {:ok, names} -> names |> Enum.sort() |> Enum.filter(&File.dir?(Path.join(ops_dir, &1)))
      {:error, _} -> []
    end
  end

  @doc """
  Deletes the operation's entry alone and syncs its directory, so the
  entry stays gone after a power loss. An entry that is already gone is
  fine. `{:error, reason}` means the entry is still in place.
  """
  @spec discard(String.t(), String.t()) :: :ok | {:error, String.t()}
  def discard(ops_dir, id) do
    dir = op_dir(ops_dir, id)
    path = Path.join(dir, @entry)

    case File.rm(path) do
      :ok -> sync_dirs([dir])
      {:error, :enoent} -> :ok
      {:error, reason} -> file_error("remove", path, reason)
    end
  end

  @doc """
  Deletes the operation's entry and its `pid`, `exit`, `stopped` and
  `unstarted` files, after the hub has acknowledged its result. `out` and
  `err` stay for `sweep/3`. Files that are already gone are fine.
  """
  @spec forget(String.t(), String.t()) :: :ok | {:error, String.t()}
  def forget(ops_dir, id) do
    dir = op_dir(ops_dir, id)

    Enum.reduce_while(@forgotten, :ok, fn name, :ok ->
      path = Path.join(dir, name)

      case File.rm(path) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, reason} -> {:halt, file_error("remove", path, reason)}
      end
    end)
  end

  @doc """
  Removes every operation directory under `ops_dir` that has no entry and
  was last changed more than `max_age` seconds before `now` (POSIX
  seconds), and returns the removed IDs. `forget/2` changes the directory,
  so its age counts from the acknowledgement. A directory that can't be
  removed is logged and tried again by the next sweep.
  """
  @spec sweep(String.t(), integer(), non_neg_integer()) :: [String.t()]
  def sweep(ops_dir, now, max_age) do
    for id <- op_ids(ops_dir),
        expired?(op_dir(ops_dir, id), now - max_age),
        removed?(ops_dir, id),
        do: id
  end

  defp expired?(dir, cutoff) do
    not File.exists?(Path.join(dir, @entry)) and
      match?({:ok, %File.Stat{mtime: mtime}} when mtime < cutoff, File.stat(dir, time: :posix))
  end

  defp removed?(ops_dir, id) do
    case File.rm_rf(op_dir(ops_dir, id)) do
      {:ok, _removed} ->
        true

      {:error, reason, file} ->
        Logger.warning("couldn't sweep #{file} (#{:file.format_error(reason)})")
        false
    end
  end

  defp file_error(action, path, reason),
    do: {:error, "can't #{action} #{path} (#{:file.format_error(reason)})"}
end
