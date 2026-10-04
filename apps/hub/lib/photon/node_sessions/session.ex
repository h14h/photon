defmodule Photon.NodeSessions.Session do
  @moduledoc """
  The hub's record of an agent session on a node. `status` follows the
  node's run-state records: `pending` until the node accepts the first
  input, then `running`, `idle` or `stopped`. `next_offset` is how many of
  the node's log records the hub holds.
  """

  # Data: an Ecto schema, no behaviour of its own.
  use Boundary, type: :strict, deps: [Ecto]

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :string, autogenerate: false}
  schema "node_sessions" do
    field(:node_id, :string)
    field(:title, :string)
    field(:origin, :string)
    field(:config, :map)
    field(:status, :string)
    field(:next_offset, :integer, default: 0)
    field(:last_answer, :string)
    field(:last_failure, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
