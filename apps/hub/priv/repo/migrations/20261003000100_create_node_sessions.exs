defmodule Photon.Repo.Migrations.CreateNodeSessions do
  use Ecto.Migration

  def change do
    create table(:node_sessions, primary_key: false) do
      add :id, :string, primary_key: true
      add :node_id, :string, null: false
      add :title, :string, null: false
      add :origin, :string, null: false
      add :config, :map, null: false
      add :status, :string, null: false
      add :next_offset, :integer, null: false, default: 0
      add :last_answer, :text
      add :last_failure, :text
      timestamps(type: :utc_datetime_usec)
    end

    create index(:node_sessions, [:node_id])

    create table(:node_events, primary_key: false) do
      add :session_id, :string, primary_key: true
      add :offset, :integer, primary_key: true
      add :record, :map, null: false
    end

    create table(:node_inputs, primary_key: false) do
      add :id, :string, primary_key: true
      add :session_id, :string, null: false
      add :input, :map, null: false
      add :state, :string, null: false
      add :answer, :text
      add :failure, :text
      timestamps(type: :utc_datetime_usec)
    end

    create index(:node_inputs, [:session_id, :state])
  end
end
