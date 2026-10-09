defmodule PhotonNode.Ops.Owner do
  @moduledoc """
  The contract between an operation process and its owner, which persists
  its snapshots, forwards them, and decides what a crash means: the
  executor (`PhotonNode.Executor`) for the hub's operations, or a test's
  stand-in. The owner is `{owner_module, owner_id}`, named in data, so
  operation processes never call it by name and Boundary sees no
  dependency from `PhotonNode.Ops` on it.

  Every implementation must keep this: an operation process never dies
  because of its owner. `checkpoint/2` and `report/2` catch every exit
  from the owner, not only `:noproc` (a timeout, or an owner that dies
  while the call waits), and return `:ignored` and `:down`. An uncaught
  exit would stop `PhotonNode.Ops.Shell`, whose `terminate/2` kills the
  running command.
  """

  alias PhotonCore.Operation

  @typedoc "Who owns an operation: the implementing module and its own ID for the owner."
  @type t :: {module(), term()}

  @doc """
  Persists a checkpoint the operation must not act on until it is stored
  (a shell command's `process` checkpoint). Only `:ok`, once it is stored,
  lets the operation act. `:cancel`: cancel instead. `:ignored`: the owner
  doesn't know the operation or didn't answer (any exit). `{:error,
  reason}`: it couldn't be stored, and the operation fails.
  """
  @callback checkpoint(owner_id :: term(), op :: Operation.t()) ::
              :ok | :cancel | :ignored | {:error, String.t()}

  @doc """
  Persists a snapshot, then forwards it. Returns `:down` if the owner isn't
  there to take it (any exit); the operation keeps the snapshot and resends
  it when asked.
  """
  @callback report(owner_id :: term(), op :: Operation.t()) :: :ok | :down

  @doc """
  Streams new output of a running operation (`stream` is `"out"` or
  `"err"`). Live only: never stored, and lost if nobody takes it.
  """
  @callback output(
              owner_id :: term(),
              op_id :: String.t(),
              stream :: String.t(),
              text :: String.t()
            ) ::
              :ok

  @doc "Calls the owner's `checkpoint/2`."
  @spec checkpoint(t(), Operation.t()) :: :ok | :cancel | :ignored | {:error, String.t()}
  def checkpoint({module, id}, op), do: module.checkpoint(id, op)

  @doc "Calls the owner's `report/2`."
  @spec report(t(), Operation.t()) :: :ok | :down
  def report({module, id}, op), do: module.report(id, op)

  @doc "Calls the owner's `output/4`."
  @spec output(t(), String.t(), String.t(), String.t()) :: :ok
  def output({module, id}, op_id, stream, text), do: module.output(id, op_id, stream, text)
end
