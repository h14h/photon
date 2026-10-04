defmodule Photon.PrivateFile do
  @moduledoc """
  Writes files only the hub's user may read (mode 0600), whole or not at
  all: the data goes to a temporary file beside the target, which is synced
  and then renamed over it. A crash mid-write leaves the old file intact
  rather than a truncated one, which matters for `chatgpt.json`: losing a
  rotated refresh token means signing in again.
  """

  use Boundary, deps: []

  @doc "Replaces `path` with `data`, mode 0600, creating its directory. Raises on failure."
  @spec write!(Path.t(), iodata()) :: :ok
  def write!(path, data) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    temp = Path.join(dir, ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp")

    try do
      # Created empty and narrowed before any data goes in.
      File.write!(temp, "", [:exclusive])
      File.chmod!(temp, 0o600)
      {:ok, :ok} = File.open(temp, [:write, :binary], &write_synced(&1, data))
      File.rename!(temp, path)
    after
      # Gone after a successful rename; this cleans up after a failure.
      _ = File.rm(temp)
    end
  end

  defp write_synced(device, data) do
    :ok = IO.binwrite(device, data)
    :ok = :file.sync(device)
  end
end
