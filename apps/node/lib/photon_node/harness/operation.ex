defmodule PhotonNode.Harness.Operation do
  @moduledoc """
  A serializable description of work a tool call asked for, advanced by an
  operation process (see `PhotonNode.Harness.Ops`). Every update is a full
  snapshot:

      %{"id", "type", "version", "status", "max_output_length", "state"}

  Statuses: `ready` (not started), `awaiting` (in progress), `canceling`, and
  the terminal `completed`, `failed`, `canceled`.

  Data and pure functions over it. `new/4` mints the operation's ID from
  the clock and random bytes (`PhotonCore.ID.new/1`), so translators that
  build operations aren't repeatable; tests match on the `op_` prefix.
  """

  # Functional core (see PhotonNode.Harness): no processes, no I/O.
  use Boundary, type: :strict, deps: [PhotonCore]

  @terminal ~w(completed failed canceled)

  @typedoc "An operation snapshot; see the moduledoc."
  @type t :: %{optional(String.t()) => term()}

  @doc "A `ready` operation of `type` with a fresh ID."
  @spec new(String.t(), pos_integer(), map(), pos_integer() | nil) :: t()
  def new(type, version, state, max_output_length \\ nil) do
    %{
      "id" => PhotonCore.ID.new("op_"),
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
end
