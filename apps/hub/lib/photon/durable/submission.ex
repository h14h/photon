defmodule Photon.Durable.Submission do
  @moduledoc """
  Input handed to a conversation. While the conversation is busy it waits
  `queued` in the inbox: `mode` `"steer"` joins the running work after the
  current tool round, `"follow_up"` starts the next run once this one
  answers. Then `placed` (as a user entry), and finally `done` (answered) or
  `unanswered` (with a `reason`), or `withdrawn` before it was placed.

  `content` holds `"parts"` (message content) and an optional `"source"`
  saying where it came from, such as a node report or a routine.
  """

  # Data: an Ecto schema, no behaviour of its own.
  use Boundary, type: :strict, deps: [Ecto]

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :string, autogenerate: false}
  schema "submissions" do
    field(:conversation_id, :string)
    field(:request_id, :string)
    field(:mode, :string)
    field(:content, :map)
    field(:status, :string)
    field(:reason, :string)
    field(:entry_id, :string)
    field(:answer_entry_id, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
