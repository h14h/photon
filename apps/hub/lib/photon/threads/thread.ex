defmodule Photon.Threads.Thread do
  @moduledoc """
  A thread: one durable agent conversation in a project (section 2.4 of
  `docs/plans/step-2-projects-and-threads.md`). Its `id` is the ID of its
  conversation, which runs under the `"thread"` profile.

  `title` comes from the first message. `active_at` is when the thread
  last got a message; threads are listed by it, newest first. Whether a
  thread is running isn't stored: it is derived from its durable run.
  """

  # Data: an Ecto schema, no behaviour of its own.
  use Boundary, type: :strict, deps: [Ecto]

  use Ecto.Schema

  @type t :: %__MODULE__{
          id: String.t() | nil,
          project_id: String.t() | nil,
          title: String.t() | nil,
          active_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :string, autogenerate: false}
  schema "threads" do
    field(:project_id, :string)
    field(:title, :string)
    field(:active_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
