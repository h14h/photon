defmodule Photon.Skills.Skill do
  @moduledoc """
  A skill: instructions an agent loads when a task calls for them.

  `name` is unique; agents load the skill by it and its page's URL uses
  it. `description` is what agents see before loading. `version` is 1
  when the skill is created and goes up by one on every save.

  `origin` is how it arrived: `"written"` in the app, `"pasted"` as a
  SKILL.md, or `"fetched"` from `source_url`. `install_notes` says what
  install left out and why, as shown at install. `files_left_out` are the
  paths install didn't bring that an agent might go looking for (at most
  20; `[]` for a written skill).
  """

  # Data: an Ecto schema, no behaviour of its own.
  use Boundary, type: :strict, deps: [Ecto]

  use Ecto.Schema

  @typedoc "How a skill arrived."
  @type origin :: String.t()

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          instructions: String.t() | nil,
          version: pos_integer() | nil,
          origin: origin() | nil,
          source_url: String.t() | nil,
          install_notes: String.t() | nil,
          files_left_out: [String.t()],
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :string, autogenerate: false}
  schema "skills" do
    field(:name, :string)
    field(:description, :string)
    field(:instructions, :string)
    field(:version, :integer)
    field(:origin, :string)
    field(:source_url, :string)
    field(:install_notes, :string)
    field(:files_left_out, {:array, :string}, default: [])
    timestamps(type: :utc_datetime_usec)
  end
end
