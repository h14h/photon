defmodule Photon.Durable.Signal do
  @moduledoc """
  A durable record that something outside the harness happened, such as a
  node finishing work. Tasks can wait on a signal's key; because the record
  is kept, a task that starts waiting after the fact still wakes.
  """

  # Data: an Ecto schema, no behaviour of its own.
  use Boundary, type: :strict, deps: [Ecto]

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:key, :string, autogenerate: false}
  schema "signals" do
    field(:payload, :map)
    field(:inserted_at, :utc_datetime_usec)
  end
end
