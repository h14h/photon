defmodule Photon.Durable.Doc do
  @moduledoc """
  Typed JSON state kept next to transcripts and changed in commits. `scope` is
  a conversation ID or `"global"`.
  """

  # Data: an Ecto schema, no behaviour of its own.
  use Boundary, type: :strict, deps: [Ecto]

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  schema "docs" do
    field(:scope, :string, primary_key: true)
    field(:kind, :string, primary_key: true)
    field(:data, :map)
    field(:updated_at, :utc_datetime_usec)
  end
end
