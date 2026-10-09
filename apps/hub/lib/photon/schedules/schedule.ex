defmodule Photon.Schedules.Schedule do
  @moduledoc """
  A schedule: a prompt that fires at set times.

  Where it fires follows from two columns (`Photon.Schedules.Rules.target/1`):
  with no `project_id` it is Blip's, and posts into Blip's conversation
  (`conversation_id`); in a project it wakes the thread `conversation_id`
  names, or, with no `conversation_id`, starts a new thread each time.

  `first_at` is the first time, and with `every_minutes` the grid of
  times after it (nil for a one-off). `version` goes up by one on every
  edit. `task_id` is the routine task that carries the current version;
  the schedule's next time and state are read from that task, never
  stored here (rule 15). `created_by` is `"owner"` or `"blip"`.
  `asked_by` says why Blip made one: `"owner"` when the owner wrote to the
  run that called the tool, `"blip"` when Blip set it up on its own; nil
  for the owner's. Every firing carries both in its source, so a thread a
  Blip-made schedule starts counts as Blip's work, and a firing of a
  reminder the owner asked for reads as a schedule, not as Blip's
  follow-up (`Photon.Assistant.Origin`).

  `last_run_at`, `last_outcome` and `last_thread_id` sum up the last
  firing, run-now included; `last_outcome` is `"failed"` when the task
  failed.
  """

  # Data: an Ecto schema, no behaviour of its own.
  use Boundary, type: :strict, deps: [Ecto]

  use Ecto.Schema

  @typedoc "What the last firing did, as `Photon.Schedules.Rules.fire/2` names it."
  @type outcome :: String.t()

  @type t :: %__MODULE__{
          id: String.t() | nil,
          project_id: String.t() | nil,
          conversation_id: String.t() | nil,
          prompt: String.t() | nil,
          first_at: DateTime.t() | nil,
          every_minutes: pos_integer() | nil,
          version: pos_integer() | nil,
          task_id: String.t() | nil,
          created_by: String.t() | nil,
          asked_by: String.t() | nil,
          last_run_at: DateTime.t() | nil,
          last_outcome: outcome() | nil,
          last_thread_id: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :string, autogenerate: false}
  schema "schedules" do
    field(:project_id, :string)
    field(:conversation_id, :string)
    field(:prompt, :string)
    field(:first_at, :utc_datetime_usec)
    field(:every_minutes, :integer)
    field(:version, :integer)
    field(:task_id, :string)
    field(:created_by, :string)
    field(:asked_by, :string)
    field(:last_run_at, :utc_datetime_usec)
    field(:last_outcome, :string)
    field(:last_thread_id, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
