defmodule Photon.Questions.Question do
  @moduledoc """
  An `ask_blip` question: one per tool call (`task_id`), asked by thread
  `thread_id`.

  `status` moves from `"asked"` (Blip has it) to `"with_owner"` (passed
  on by Blip or the hub: `passed_by`), and ends `"answered"` or
  `"withdrawn"` (the call ended first); `Photon.Questions.Rules.step/2`
  has the transitions.

  `thread_title`, `project_slug` and `project_name` are as they were when
  the thread asked; the pages show current titles. `submission_id` is the
  message in Blip's conversation that carries the question. `wording` is
  how Blip put the question to the owner, nil when the hub passed the
  thread's own words on.
  """

  # Data: an Ecto schema, no behaviour of its own.
  use Boundary, type: :strict, deps: [Ecto]

  use Ecto.Schema

  @typedoc ~s{Where a question is: `"asked"`, `"with_owner"`, `"answered"` or `"withdrawn"`.}
  @type status :: String.t()

  @type t :: %__MODULE__{
          id: String.t() | nil,
          task_id: String.t() | nil,
          thread_id: String.t() | nil,
          project_id: String.t() | nil,
          thread_title: String.t() | nil,
          project_slug: String.t() | nil,
          project_name: String.t() | nil,
          question: String.t() | nil,
          status: status() | nil,
          submission_id: String.t() | nil,
          wording: String.t() | nil,
          passed_by: String.t() | nil,
          answer: String.t() | nil,
          answered_by: String.t() | nil,
          passed_at: DateTime.t() | nil,
          answered_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :string, autogenerate: false}
  schema "questions" do
    field(:task_id, :string)
    field(:thread_id, :string)
    field(:project_id, :string)
    field(:thread_title, :string)
    field(:project_slug, :string)
    field(:project_name, :string)
    field(:question, :string)
    field(:status, :string)
    field(:submission_id, :string)
    field(:wording, :string)
    field(:passed_by, :string)
    field(:answer, :string)
    field(:answered_by, :string)
    field(:passed_at, :utc_datetime_usec)
    field(:answered_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
