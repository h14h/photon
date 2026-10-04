defmodule Photon.Durable.TaskRecord do
  @moduledoc """
  A durable task: a state machine that checkpoints at every step.

  `status` is `pending`, `running`, `waiting` (on `waiting`: other tasks, a
  time, or a signal), or terminal: `done`, `failed`, `aborted`. `phase` and
  `checkpoint` say where the next step resumes; `runs` counts how many times
  the current phase has started, so a step can tell it is being retried after
  a crash. A task is owned by its conversation (`owner_task_id` nil) or by
  another task. `background` tasks don't keep their owner busy and survive
  its abort.
  """

  # Data: an Ecto schema, no behaviour of its own.
  use Boundary, type: :strict, deps: [Ecto]

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @terminal ~w(done failed aborted)

  @primary_key {:id, :string, autogenerate: false}
  schema "tasks" do
    field(:kind, :string)
    field(:conversation_id, :string)
    field(:owner_task_id, :string)
    field(:background, :boolean, default: false)
    field(:status, :string)
    field(:phase, :string)
    field(:input, :map)
    field(:checkpoint, :map)
    field(:waiting, :map)
    field(:outcome, :map)
    field(:runs, :integer, default: 0)
    field(:abort_requested, :boolean, default: false)
    field(:request_id, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @spec terminal_statuses() :: [String.t()]
  def terminal_statuses, do: @terminal

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in @terminal
end
