defmodule Photon.NodeKeys.Key do
  @moduledoc """
  A node's key, as the hub keeps it: the SHA-256 of the key (never the key
  itself); the tailnet device it is tied to (`device`, Tailscale's stable
  ID, and that device's name), which outlives the key when a new one
  replaces it; `generation`, bumped with every new key; and, for a key no
  device is tied to yet, when it stops working unused (`expires_at`).
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
    timestamps(type: :utc_datetime_usec)
  end
end
