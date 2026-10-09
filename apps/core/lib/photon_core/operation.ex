defmodule PhotonCore.Operation do
  @moduledoc """
  A serializable description of work on a machine, advanced by an operation
  process on the node that runs it. Every update is a full snapshot:

      %{"id", "type", "version", "status", "max_output_length", "state"}

  Statuses: `ready` (not started), `awaiting` (in progress), `canceling`, and
  the terminal `completed`, `failed`, `canceled`. A terminal snapshot is the
  operation's result.

  The node journals and reports snapshots and the hub reads results from
  them; `PhotonCore.Operation.Wire` carries them. `new/5` takes the ID as
  an argument: the hub derives an op ID from its tool call's ID, so a
  restart finds the same operation, and the node uses the ID the hub sent.
  """

  # A command is passed to the shell as one argument, and Linux refuses one
  # over 128 KB (MAX_ARG_STRLEN), so a longer one couldn't run anyway.
  @max_command_bytes 100_000

  # The largest base64 image a node puts in a result; the hub asks for less.
  @max_image_bytes 5_000_000

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

  @doc "The largest `shell` command, in bytes, that either side accepts."
  @spec max_command_bytes() :: pos_integer()
  def max_command_bytes, do: @max_command_bytes

  @doc "The largest `max_size` a `view_image` op may ask for, in base64 bytes."
  @spec max_image_bytes() :: pos_integer()
  def max_image_bytes, do: @max_image_bytes

  @doc "Every status, terminal or not."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses
end
