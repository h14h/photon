defmodule Photon.NodeKeys.Key do
  @moduledoc """
  A node's key, as the hub keeps it: the SHA-256 of the key, never the key
  itself. `expires_at` is when a key no device is tied to yet stops
  working unused; `revoked_at` marks a removed node, whose row stays, with
  no usable key, to keep its machine out of the GUI (see `Photon.NodeKeys`).
  """

  # Data: an Ecto schema, no behaviour of its own.
  use Boundary, type: :strict, deps: [Ecto]

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:node_id, :string, autogenerate: false}
  schema "node_keys" do
    field(:key_hash, :binary)
    field(:device, :string)
    field(:device_name, :string)
    field(:generation, :integer, default: 0)
    field(:expires_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
