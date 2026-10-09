defmodule Photon.Repo.Migrations.CreateQuestions do
  use Ecto.Migration

  # A thread's `ask_blip` questions: one row per tool call, from asked to
  # answered or withdrawn.
  def change do
    create table(:questions, primary_key: false) do
      add :id, :string, primary_key: true
      # The `ask_blip` call's tool task; a rerun finds its question by it.
      add :task_id, :string, null: false
      add :thread_id, references(:threads, type: :string, on_delete: :delete_all), null: false
      add :project_id, :string, null: false
      # Where the thread was when it asked, for Blip's signal and notices.
      add :thread_title, :string, null: false
      add :project_slug, :string, null: false
      add :project_name, :string, null: false
      add :question, :text, null: false
      # "asked", "with_owner", "answered" or "withdrawn".
      add :status, :string, null: false
      # The message in Blip's conversation that carries it.
      add :submission_id, :string
      # Blip's words to the owner; nil when the hub passed it on.
      add :wording, :text
      add :passed_by, :string
      add :answer, :text
      add :answered_by, :string
      add :passed_at, :utc_datetime_usec
      add :answered_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:questions, [:task_id])
    create index(:questions, [:thread_id])
    create index(:questions, [:status])
  end
end
