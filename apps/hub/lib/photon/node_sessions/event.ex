defmodule Photon.NodeSessions.Event do
  @moduledoc "One record of a node session's log, at its offset."

  # Data: an Ecto schema, no behaviour of its own.
  use Boundary, type: :strict, deps: [Ecto]

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  schema "node_events" do
    field(:session_id, :string, primary_key: true)
    field(:offset, :integer, primary_key: true)
    field(:record, :map)
  end
end
