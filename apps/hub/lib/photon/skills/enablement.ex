defmodule Photon.Skills.Enablement do
  @moduledoc """
  One skill turned on in one scope. A skill is on for a scope exactly when
  this row exists; there is no "off" row.

  `scope` is `"blip"`, a project's ID (`p_...`), or `"machine:<id>"` for a
  machine (`"machine:mm1"`). Only `Photon.Skills` turns it to and from the
  `:blip | {:project, id} | {:machine, id}` the rest of the code uses.
  """

  # Data: an Ecto schema, no behaviour of its own.
  use Boundary, type: :strict, deps: [Ecto]

  use Ecto.Schema

  @type t :: %__MODULE__{
          skill_id: String.t() | nil,
          scope: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @primary_key false
  schema "skill_enablements" do
    field(:skill_id, :string)
    field(:scope, :string)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
