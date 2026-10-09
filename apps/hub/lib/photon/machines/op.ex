defmodule Photon.Machines.Op do
  @moduledoc """
  The hub's durable record of an operation on a machine: one row per tool
  call, keyed by the op ID derived from the call's durable task.

  `status` is `open` until a terminal snapshot arrives, then `finished`
  (the snapshot is kept in `result` until the tool claims it) or `closed`
  (the tool has its result, or the op was canceled; `result` is null).
  `output` is what a shell command printed, kept when the call ended
  another way and the op's final snapshot carried output; nil otherwise.
  The flags are facts the hub has learned:

    * `confirmed`: the node has sent a snapshot for the op, so it knows it
    * `pushed`: an `op.start` was built for the op at least once
    * `cancel`: the call ended another way, and the op must not run

  `Photon.Machines.Rules` decides every change
  (`docs/operations.md#hub-rules`).
  """

  # Data: an Ecto schema, no behaviour of its own.
  use Boundary, type: :strict, deps: [Ecto]

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :string, autogenerate: false}
  schema "machine_ops" do
    field(:machine, :string)
    field(:kind, :string)
    field(:args, :map)
    field(:conversation_id, :string)
    field(:call_id, :string)
    field(:task_id, :string)
    field(:status, :string, default: "open")
    field(:confirmed, :boolean, default: false)
    field(:pushed, :boolean, default: false)
    field(:cancel, :boolean, default: false)
    field(:result, :map)
    field(:output, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
