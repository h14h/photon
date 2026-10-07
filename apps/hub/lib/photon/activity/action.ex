defmodule Photon.Activity.Action do
  @moduledoc """
  One row of the activity log (section 6.1 of
  `docs/plans/step-4-blip-as-coordinator.md`): something Blip did, and
  who asked for it. Written once, in the commit that stored what it
  records, and never changed.

    * `kind` - `"call"` (a tool call, `tool` its name) or `"message"`
      (Blip told the owner something in a run the owner didn't type into;
      `tool` is nil)
    * `summary` - the line the page shows, at most 200 characters
      (`Photon.Activity.Rules.summary/3`, `message_summary/1`)
    * `status` - the call's result: `"ok"`, `"error"`, `"interrupted"` or
      `"aborted"`; `"ok"` for a message
    * `changes` - whether the tool changes something
      (`Photon.Activity.Rules.changes?/1`); false for reads and messages
    * `origin` and `origin_id` - who asked: `"owner"`, `"thread"` (the
      thread whose question it was), `"schedule"` (the schedule),
      `"follow_up"` (the thread it followed up on, the schedule Blip
      made for itself, `"digest"` or `"review"` for ambient mode's
      digest and daily review, or nil) or `"unknown"`
    * `project_id`, `thread_id` - what the call acted on, from its result's
      details; nil when it named none
    * `entry_id` - the `"tool_result"` entry, or for a message the answer
      entry, in Blip's conversation; one row per entry

  The IDs are plain strings, not foreign keys: a row naming something
  that is gone still says what happened.
  """

  # Data: an Ecto schema, no behaviour of its own.
  use Boundary, type: :strict, deps: [Ecto]

  use Ecto.Schema

  @type t :: %__MODULE__{
          id: String.t() | nil,
          kind: String.t() | nil,
          tool: String.t() | nil,
          summary: String.t() | nil,
          status: String.t() | nil,
          changes: boolean() | nil,
          origin: String.t() | nil,
          origin_id: String.t() | nil,
          project_id: String.t() | nil,
          thread_id: String.t() | nil,
          entry_id: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @primary_key {:id, :string, autogenerate: false}
  schema "activity" do
    field(:kind, :string)
    field(:tool, :string)
    field(:summary, :string)
    field(:status, :string)
    field(:changes, :boolean)
    field(:origin, :string)
    field(:origin_id, :string)
    field(:project_id, :string)
    field(:thread_id, :string)
    field(:entry_id, :string)
    field(:inserted_at, :utc_datetime_usec)
  end
end
