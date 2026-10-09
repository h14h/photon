defmodule Photon.Threads.Thread do
  @moduledoc """
  A thread: one durable agent conversation in a project. Its `id` is the ID
  of its conversation, which runs under the `"thread"` profile.

  `title` comes from the first message. `active_at` is when the thread
  last got a message; threads are listed by it, newest first. Whether a
  thread is running isn't stored: it is derived from its durable run.

  The rest are facts recorded when something happened, from which
  `Photon.Threads.State` works out the thread's state at read time:

    * `started_by` - `"owner"`, `"blip"` or `"schedule"`, from the first
      message's source
    * `last_run_status` - how the last run ended: `"done"`, `"failed"` or
      `"stopped"`; nil before any run has ended
    * `last_run_ended_at` - when it ended
    * `last_run_asked` - whether its final answer ended with a question
      to the user
    * `last_run_note` - at most 280 characters about how it ended: the
      answer's first paragraph, the question, or the reason it failed
    * `seen_at` - when the owner last had the thread's page open after a
      run ended
    * `resolved_at` - when the owner marked it resolved; a new message
      clears it
    * `reviewed_at` - when ambient mode's daily review last listed it; a
      fact the review reads, never part of the thread's state
  """

  # Data: an Ecto schema, no behaviour of its own.
  use Boundary, type: :strict, deps: [Ecto]

  use Ecto.Schema

  @type t :: %__MODULE__{
          id: String.t() | nil,
          project_id: String.t() | nil,
          title: String.t() | nil,
          active_at: DateTime.t() | nil,
          started_by: String.t(),
          last_run_status: String.t() | nil,
          last_run_ended_at: DateTime.t() | nil,
          last_run_asked: boolean(),
          last_run_note: String.t() | nil,
          seen_at: DateTime.t() | nil,
          resolved_at: DateTime.t() | nil,
          reviewed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :string, autogenerate: false}
  schema "threads" do
    field(:project_id, :string)
    field(:title, :string)
    field(:active_at, :utc_datetime_usec)
    field(:started_by, :string, default: "owner")
    field(:last_run_status, :string)
    field(:last_run_ended_at, :utc_datetime_usec)
    field(:last_run_asked, :boolean, default: false)
    field(:last_run_note, :string)
    field(:seen_at, :utc_datetime_usec)
    field(:resolved_at, :utc_datetime_usec)
    field(:reviewed_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
