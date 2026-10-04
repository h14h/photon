defmodule Photon.NodeKeys.Key do
  @moduledoc """
  A node's key, as the hub keeps it: the SHA-256 of the key (never the key
  itself) and, once the node has connected with it, the tailnet device it
  is tied to (`device`, Tailscale's stable ID, and that device's name).
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
    timestamps(type: :utc_datetime_usec)
  end
end
