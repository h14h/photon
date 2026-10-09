defmodule PhotonNode.Ops do
  @moduledoc """
  The node's operation layer: one process per operation, registered by
  operation ID, and this module, the API over them. A `shell` operation
  runs in `PhotonNode.Ops.Shell`; `view_image` is a job
  (`PhotonNode.Ops.ViewImage`) run once by `PhotonNode.Ops.Job`.

  Every operation has an owner (`PhotonNode.Ops.Owner`), given to `add/2`
  as `{owner_module, owner_id}`: `PhotonNode.Executor` for the hub's
  operations, or a stand-in in tests. The owner persists each snapshot
  before acting on it, monitors the process, and decides what its exit
  means; the processes are `:temporary` (see `PhotonNode`).

  `add/2` is idempotent per ID. Adding an operation that is already running
  asks it to resend its latest snapshot instead, which is how a restarted
  owner catches up.

  Operation processes take two messages, both sent only from here:
  `:resend` (report the latest snapshot again) and `:cancel`. They are
  plain sends to a local, registered process; if that process exits
  instead of answering, the owner's monitor sees it.
  """

  # `Owner` and `Env` are exported for the executor.
  use Boundary,
    deps: [PhotonCore],
    exports: [Owner, Env]

  alias PhotonCore.Operation
  alias PhotonNode.Ops.{Job, Owner, Shell, ViewImage}

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

  @doc "Whether a process runs the operation now."
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
      case DynamicSupervisor.start_child(PhotonNode.OpSupervisor, child) do
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
