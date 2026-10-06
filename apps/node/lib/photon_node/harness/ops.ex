defmodule PhotonNode.Harness.Ops do
  @moduledoc """
  The API over operation processes: one process per operation under
  `PhotonNode.Harness.OpSupervisor`, registered by operation ID in
  `PhotonNode.OpRegistry`. A `shell` operation runs in
  `PhotonNode.Harness.Ops.Shell`; `view_image` is a job
  (`PhotonNode.Harness.Ops.ViewImage`) run once by
  `PhotonNode.Harness.Ops.Job`.

  Every operation has an owner (`PhotonNode.Harness.Ops.Owner`), given to
  `add/2` as `{owner_module, owner_id}`: `PhotonNode.Executor` for the
  hub's operations, or a stand-in in tests. Each process reports its
  snapshots to the owner, which persists them before acting on them. A checkpoint the
  operation must not act on until it is stored (a shell command's start)
  goes through the owner's `checkpoint/2`, a call. An operation process
  never dies because of its owner (see `PhotonNode.Harness.Ops.Owner`).

  `add/2` is idempotent per ID. Adding an operation that is already running
  asks it to resend its latest snapshot instead, which is how a restarted
  owner catches up.

  Operation processes take two messages, both sent only from here:
  `:resend` (report the latest snapshot again) and `:cancel`. They are
  plain sends to a local, registered process; if that process exits
  instead of answering, the owner's monitor sees it.

  Lifecycle: operation processes are `:temporary`. A crash isn't restarted
  by the supervisor; the owner monitors the process and decides (the
  executor applies `PhotonNode.Executor.Rules.down/3`).
  """

  alias PhotonCore.Operation
  alias PhotonNode.Harness.Ops.{Job, Owner, Shell, ViewImage}

  @doc """
  Starts (or resumes, from its checkpoint) an operation for its owner.
  Returns `{:ok, pid}` with the operation's process, which the owner
  monitors, or `{:error, reason}`.
  """
  @spec add(Operation.t(), Owner.t()) :: {:ok, pid()} | {:error, term()}
  def add(op, {_module, _id} = owner) do
    case running(op["id"]) do
      {:ok, pid} -> resend(pid)
      :error -> start(op, owner)
    end
  end

  @doc "Asks a running operation to cancel. Unknown or finished operations are ignored."
  @spec cancel(String.t()) :: :ok
  def cancel(op_id) do
    case Registry.lookup(PhotonNode.OpRegistry, op_id) do
      [{pid, _}] -> send(pid, :cancel)
      [] -> :ok
    end

    :ok
  end

  @doc """
  Whether a process runs the operation now. The executor asks before it
  decides to resume an operation from its journal.
  """
  @spec running?(String.t()) :: boolean()
  def running?(op_id), do: match?({:ok, _pid}, running(op_id))

  @doc false
  @spec via(String.t()) :: GenServer.name()
  def via(op_id), do: {:via, Registry, {PhotonNode.OpRegistry, op_id}}

  # Registry.lookup/2 can still return a process that has just exited (the
  # registry removes it asynchronously); that one is replaced.
  defp running(op_id) do
    case Registry.lookup(PhotonNode.OpRegistry, op_id) do
      [{pid, _}] -> if Process.alive?(pid), do: {:ok, pid}, else: :error
      [] -> :error
    end
  end

  defp start(op, owner) do
    with {:ok, child} <- child_spec(op, owner) do
      case DynamicSupervisor.start_child(PhotonNode.Harness.OpSupervisor, child) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> resend(pid)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp child_spec(%{"type" => "shell"} = op, owner), do: {:ok, {Shell, {op, owner}}}

  defp child_spec(%{"type" => "view_image"} = op, owner),
    do: {:ok, {Job, {ViewImage, op, owner}}}

  defp child_spec(op, _owner),
    do: {:error, "unsupported operation type #{inspect(op["type"])}"}

  defp resend(pid) do
    send(pid, :resend)
    {:ok, pid}
  end
end
