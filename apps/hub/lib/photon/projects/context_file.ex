defmodule Photon.Projects.ContextFile do
  @moduledoc """
  A project's context file: a freeform Markdown note kept on the hub, which
  the user edits on the project's pages and the project's threads read and
  write with tools.

  `key` is `name` downcased, unique within the project, so `Notes.md` and
  `notes.md` can't both exist. `version` is 1 when the file is created and
  goes up by one on every write; the user's editor saves against the
  version it loaded. `updated_by` is `"owner"`, `"blip"` or the ID of the
  thread that last wrote the file.
  """

  # Data: an Ecto schema, no behaviour of its own.
  use Boundary, type: :strict, deps: [Ecto]

  use Ecto.Schema

  @typedoc ~S(Who last wrote a file: `"owner"`, `"blip"` or a thread's ID.)
  @type writer :: String.t()

  @type t :: %__MODULE__{
          id: String.t() | nil,
          project_id: String.t() | nil,
          name: String.t() | nil,
          key: String.t() | nil,
          content: String.t() | nil,
          version: pos_integer() | nil,
          updated_by: writer() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :string, autogenerate: false}
  schema "project_files" do
    field(:project_id, :string)
    field(:name, :string)
    field(:key, :string)
    field(:content, :string)
    field(:version, :integer)
    field(:updated_by, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
