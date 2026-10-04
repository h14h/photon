defmodule Photon.Durable.Entry do
  @moduledoc """
  One immutable transcript record. Kinds the harness writes:

    * `"user"` - `%{"message" => user message, "submission_id", "source"}`
    * `"assistant"` - `%{"message" => assistant message, "usage", "model", "stop"}`
    * `"tool_result"` - `%{"message" => tool message, "name", "status", "details"}`
    * `"error"` - `%{"message" => text}`, shown but never sent to the model
    * `"reset"` - `%{"handoff" => text | nil}`; the model sees entries from
      the newest reset onward

  `seq` orders a conversation's entries.
  """

  # Data: an Ecto schema, no behaviour of its own.
  use Boundary, type: :strict, deps: [Ecto]

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :string, autogenerate: false}
  schema "entries" do
    field(:conversation_id, :string)
    field(:seq, :integer)
    field(:kind, :string)
    field(:data, :map)
    field(:inserted_at, :utc_datetime_usec)
  end
end
