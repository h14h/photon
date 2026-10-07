defmodule Photon.Repo.Migrations.Ambient do
  use Ecto.Migration

  # Ambient mode (sections 3.2 and 4.2 of
  # `docs/plans/step-5-ambient-mode.md`): the changes waiting for the next
  # digest, and when a daily review last listed a thread. No foreign keys:
  # an item whose thread, project or schedule is gone is dropped when the
  # digest reads it.
  def change do
    create table(:digest_items, primary_key: false) do
      add :id, :string, primary_key: true
      # What makes the item once: a settle's signal key,
      # "schedule:<task id>:failed", or "<kind>:<random id>".
      add :key, :string, null: false
      # "finished", "schedule_stopped", "file_written", "project_created",
      # "purpose_changed", "thread_started" or "resolved".
      add :kind, :string, null: false
      add :thread_id, :string
      add :project_id, :string
      add :schedule_id, :string
      # A context file's name, and who wrote it: a thread's ID or "user".
      add :name, :string
      add :writer, :string
      # At most 600 characters: a run's note, a failure's reason, or
      # "deleted" for a deleted file.
      add :note, :text
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:digest_items, [:key])
    create index(:digest_items, [:inserted_at])

    alter table(:threads) do
      add :reviewed_at, :utc_datetime_usec
    end
  end
end
