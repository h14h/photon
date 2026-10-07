defmodule Photon.Signals.DigestItem do
  @moduledoc """
  A change waiting for the next digest (section 3.2 of
  `docs/plans/step-5-ambient-mode.md`), collected only while ambient mode
  is on and deleted in the commit that posts the digest carrying it.

    * `key` - what makes it once: the settle's signal key
      (`Photon.Signals.Rules.key/1`), `"schedule:<task id>:failed"`, or
      `"<kind>:<random id>"` for the smaller kinds
    * `kind` - `"finished"`, `"schedule_stopped"`, `"file_written"`,
      `"project_created"`, `"purpose_changed"`, `"thread_started"` or
      `"resolved"`
    * `thread_id`, `project_id`, `schedule_id` - what it is about; nil
      when it names none (`project_id` is nil for Blip's own schedule)
    * `name`, `writer` - a context file's name, and who wrote it: a
      thread's ID or `"user"`
    * `note` - at most 600 characters: the run's note, the schedule's
      failure reason, or `"deleted"` for a deleted file

  The IDs are plain strings, not foreign keys, and titles and names are
  read when the digest is written, so a renamed thread reads with its new
  title and an item whose subject is gone is dropped then.
  """

  # Data: an Ecto schema, no behaviour of its own.
  use Boundary, type: :strict, deps: [Ecto]

  use Ecto.Schema

  @type t :: %__MODULE__{
          id: String.t() | nil,
          key: String.t() | nil,
          kind: String.t() | nil,
          thread_id: String.t() | nil,
          project_id: String.t() | nil,
          schedule_id: String.t() | nil,
          name: String.t() | nil,
          writer: String.t() | nil,
          note: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @primary_key {:id, :string, autogenerate: false}
  schema "digest_items" do
    field(:key, :string)
    field(:kind, :string)
    field(:thread_id, :string)
    field(:project_id, :string)
    field(:schedule_id, :string)
    field(:name, :string)
    field(:writer, :string)
    field(:note, :string)
    field(:inserted_at, :utc_datetime_usec)
  end
end
