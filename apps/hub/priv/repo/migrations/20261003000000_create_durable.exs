defmodule Photon.Repo.Migrations.CreateDurable do
  use Ecto.Migration

  def change do
    create table(:conversations, primary_key: false) do
      add :id, :string, primary_key: true
      add :profile, :string, null: false
      add :title, :string
      add :owner_task_id, :string
      add :parent_id, :string
      add :fork_seq, :integer
      timestamps(type: :utc_datetime_usec)
    end

    create table(:entries, primary_key: false) do
      add :id, :string, primary_key: true
      add :conversation_id, :string, null: false
      add :seq, :integer, null: false
      add :kind, :string, null: false
      add :data, :map, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:entries, [:conversation_id, :seq])

    create table(:docs, primary_key: false) do
      add :scope, :string, primary_key: true
      add :kind, :string, primary_key: true
      add :data, :map, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create table(:tasks, primary_key: false) do
      add :id, :string, primary_key: true
      add :kind, :string, null: false
      add :conversation_id, :string
      add :owner_task_id, :string
      add :background, :boolean, null: false, default: false
      add :status, :string, null: false
      add :phase, :string, null: false
      add :input, :map, null: false
      add :checkpoint, :map, null: false
      add :waiting, :map
      add :outcome, :map
      add :runs, :integer, null: false, default: 0
      add :abort_requested, :boolean, null: false, default: false
      add :request_id, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tasks, [:request_id])
    create index(:tasks, [:status])
    create index(:tasks, [:owner_task_id])
    create index(:tasks, [:conversation_id])

    create table(:submissions, primary_key: false) do
      add :id, :string, primary_key: true
      add :conversation_id, :string, null: false
      add :request_id, :string
      add :mode, :string, null: false
      add :content, :map, null: false
      add :status, :string, null: false
      add :reason, :string
      add :entry_id, :string
      add :answer_entry_id, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:submissions, [:conversation_id, :request_id])
    create index(:submissions, [:conversation_id, :status])

    create table(:signals, primary_key: false) do
      add :key, :string, primary_key: true
      add :payload, :map, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end
  end
end
