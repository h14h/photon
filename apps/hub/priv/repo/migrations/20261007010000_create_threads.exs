defmodule Photon.Repo.Migrations.CreateThreads do
  use Ecto.Migration

  def change do
    # A thread's ID is its durable conversation's ID.
    create table(:threads, primary_key: false) do
      add :id, :string, primary_key: true

      add :project_id, references(:projects, type: :string, on_delete: :delete_all),
        null: false

      add :title, :string, null: false
      add :active_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:threads, [:project_id, :active_at])
  end
end
