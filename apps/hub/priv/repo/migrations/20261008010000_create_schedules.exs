defmodule Photon.Repo.Migrations.CreateSchedules do
  use Ecto.Migration

  def change do
    # A schedule's definition and a summary of its last firing. Its next
    # time and state come from its routine task (`task_id`), never from here.
    create table(:schedules, primary_key: false) do
      add :id, :string, primary_key: true
      # Nil for Blip's own schedules.
      add :project_id, references(:projects, type: :string, on_delete: :delete_all)
      # Where a firing posts: Blip's conversation, or the thread a project
      # schedule wakes. Nil for a schedule that starts a new thread each time.
      add :conversation_id, :string
      add :prompt, :text, null: false
      add :first_at, :utc_datetime_usec, null: false
      add :every_minutes, :integer
      add :version, :integer, null: false
      add :task_id, :string
      add :created_by, :string, null: false
      add :last_run_at, :utc_datetime_usec
      add :last_outcome, :string
      add :last_thread_id, :string
      timestamps(type: :utc_datetime_usec)
    end

    create index(:schedules, [:project_id])
  end
end
