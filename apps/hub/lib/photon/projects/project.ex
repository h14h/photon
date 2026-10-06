defmodule Photon.Projects.Project do
  @moduledoc """
  A project: a purpose and a name, for any body of work (section 2.1 of
  `docs/plans/step-2-projects-and-threads.md`). Nothing else is stored
  about how the project is run.

  `slug` names the project's folder on every machine
  (`<workspace>/<slug>`) and appears in its URLs. It is made once, from the
  name, and never changes (`Photon.Projects.Rules.slug/1`).
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
