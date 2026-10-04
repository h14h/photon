defmodule Photon.NodeSessions.Input do
  @moduledoc """
  An input the hub sent (or will send) to a node session: an outbox entry.
  `state` is `queued` until the node's log shows it was accepted, then
  `accepted`, then `done` once the session goes idle (with the answer) or
  `failed` if the node rejected it. Queued inputs are resent whenever the
  node connects; the node ignores repeats by ID.
  """

  # Data: an Ecto schema, no behaviour of its own.
  use Boundary, type: :strict, deps: [Ecto]

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :string, autogenerate: false}
  schema "node_inputs" do
    field(:session_id, :string)
    field(:input, :map)
    field(:state, :string)
    field(:answer, :string)
    field(:failure, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
