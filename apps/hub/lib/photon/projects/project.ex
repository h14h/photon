defmodule Photon.Projects.Project do
  @moduledoc """
  A project: a purpose and a name, for any body of work. `slug` names its
  folder on every machine and appears in its URLs; it never changes (see
  `Photon.Projects`).
  """

  # Data: an Ecto schema, no behaviour of its own.
  use Boundary, type: :strict, deps: [Ecto]

  use Ecto.Schema

  @type t :: %__MODULE__{
          id: String.t() | nil,
          slug: String.t() | nil,
          name: String.t() | nil,
          purpose: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :string, autogenerate: false}
  schema "projects" do
    field(:slug, :string)
    field(:name, :string)
    field(:purpose, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
