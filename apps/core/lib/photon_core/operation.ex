defmodule PhotonCore.Operation do
  @moduledoc """
  A serializable description of work on a machine, advanced by an operation
  process on the node that runs it. Every update is a full snapshot:

      %{"id", "type", "version", "status", "max_output_length", "state"}

  Statuses: `ready` (not started), `awaiting` (in progress), `canceling`, and
  the terminal `completed`, `failed`, `canceled`. A terminal snapshot is the
  operation's result.

  The node and the hub share this shape: the node journals and reports
  snapshots, and the hub reads results from them. The messages that carry
  them are in `PhotonCore.Operation.Wire`.

  Data and pure functions over it. `new/5` takes the ID as an argument:
  the hub derives an op ID from its tool call's ID, so a restart finds the
  same operation, and the node uses the ID the hub sent.
  """

  @terminal ~w(completed failed canceled)
  @statuses ~w(ready awaiting canceling) ++ @terminal

  @typedoc "An operation snapshot; see the moduledoc."
  @type t :: %{optional(String.t()) => term()}

  @doc "A `ready` operation of `type` with the ID `id`."
  @spec new(String.t(), String.t(), pos_integer(), map(), pos_integer() | nil) :: t()
  def new(id, type, version, state, max_output_length) do
    %{
      "id" => id,
      "type" => type,
      "version" => version,
      "status" => "ready",
      "max_output_length" => max_output_length,
      "state" => state
    }
  end

  @doc "The next snapshot: `status`, with `changes` merged into the state."
  @spec advance(t(), String.t(), map()) :: t()
  def advance(op, status, changes),
    do: %{op | "status" => status, "state" => Map.merge(op["state"], changes)}

  @doc "The snapshot of an operation that failed with `message`."
  @spec fail(t(), String.t()) :: t()
  def fail(op, message), do: advance(op, "failed", %{"terminal_error" => message})

  @spec terminal?(t()) :: boolean()
  def terminal?(%{"status" => status}), do: status in @terminal

  @spec terminal_statuses() :: [String.t()]
  def terminal_statuses, do: @terminal

  @doc "Every status, terminal or not."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses
end
