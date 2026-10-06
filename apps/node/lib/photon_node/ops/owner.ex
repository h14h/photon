defmodule PhotonNode.Ops.Owner do
  @moduledoc """
  The contract between an operation process and whatever owns it: the
  process that persists its snapshots, forwards them, and decides what a
  crash means. The executor (`PhotonNode.Executor`) owns the hub's
  operations; tests stand in their own owner.

  An operation process is started with `{op, owner}`, where `owner` is
  `{owner_module, owner_id}`. The module is named in data, so the
  operation processes never call their owners by name, and Boundary sees no
  dependency from `PhotonNode.Ops` on them.

  What every implementation must keep: an operation process never dies
  because of its owner. `checkpoint/2` and `report/2` catch every exit
  from the owner, not only `:noproc` (a timeout, or an owner that dies
  while the call waits), and return `:ignored` and `:down`. An uncaught
  exit would stop `PhotonNode.Ops.Shell`, and its `terminate/2` kills the
  running command.
  """

  alias PhotonCore.Operation

  @typedoc "Who owns an operation: the implementing module and its own ID for the owner."
  @type t :: {module(), term()}

  @doc """
  Persists a checkpoint the operation must not act on until it is stored
  (a shell command's `process` checkpoint), and says whether to go on.

  Returns `:ok` once it is stored, `:cancel` if the operation should cancel
  instead, `:ignored` if the owner doesn't know the operation or didn't
  answer (any exit), or `{:error, reason}` if it couldn't be stored. Only
  `:ok` lets the operation act; on `{:error, reason}` it fails.
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
