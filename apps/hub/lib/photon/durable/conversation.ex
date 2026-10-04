defmodule Photon.Durable.Conversation do
  @moduledoc """
  A transcript of immutable entries. `profile` names what runs it (see
  `Photon.Durable.Profile`); `owner_task_id` is set when a task owns it, as a
  subagent's conversation is owned by the tool call that made it.
  """

  # Data: an Ecto schema, no behaviour of its own.
  use Boundary, type: :strict, deps: [Ecto]

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :string, autogenerate: false}
  schema "conversations" do
    field(:profile, :string)
    field(:title, :string)
    field(:owner_task_id, :string)
    field(:parent_id, :string)
    field(:fork_seq, :integer)
    timestamps(type: :utc_datetime_usec)
  end
end
