defmodule PhotonNode.TestLink do
  @moduledoc """
  A hub link (`PhotonNode.Executor.Link`) for the executor's boundary
  tests, set as the node's `:link`. The test process registers itself
  under this module's name and gets what the executor sends the hub:

    * `{:snapshot, op, journaled}` for every snapshot, where `journaled` is
      the snapshot in the operation's journal entry at that moment (nil if
      it has none), so a test can check the journal came first
    * `{:output, op_id, stream, text}` for live output

  `hold/1` makes the executor wait in the link on the next snapshot that
  matches: the test gets `{:held, op_id, executor_pid}` and the executor
  waits until it gets `:release` (or is killed).
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  @behaviour PhotonNode.Executor.Link

  alias PhotonNode.Config
  alias PhotonNode.Executor.Journal

  @hold {__MODULE__, :hold}

  @impl true
  def snapshot(op) do
    notify({:snapshot, op, journaled(op["id"])})
    maybe_hold(op)
  end

  @impl true
  def output(op_id, stream, text), do: notify({:output, op_id, stream, text})

  @doc "Holds the executor in the link on the next snapshot `match?` accepts (once)."
  def hold(match?), do: :persistent_term.put(@hold, match?)

  @doc "Drops a hold that never matched."
  def unhold do
    _ = :persistent_term.erase(@hold)
    :ok
  end

  defp notify(message) do
    if pid = Process.whereis(__MODULE__), do: send(pid, message)
    :ok
  end

  defp journaled(id) do
    case Journal.read(Config.ops_dir(PhotonNode.config()), id) do
      {:ok, %{"op" => op}} -> op
      _ -> nil
    end
  end

  defp maybe_hold(op) do
    match? = :persistent_term.get(@hold, nil)

    if match? && match?.(op) do
      unhold()
      notify({:held, op["id"], self()})

      receive do
        :release -> :ok
      end
    else
      :ok
    end
  end
end
