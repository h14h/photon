defmodule Photon.Repo.Migrations.CreateSkills do
  use Ecto.Migration

  def change do
    create table(:skills, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :description, :text, null: false
      add :instructions, :text, null: false
      add :version, :integer, null: false
      add :origin, :string, null: false
      add :source_url, :string
      add :install_notes, :text
      # The paths install left out that an agent might look for; JSON in SQLite.
      add :files_left_out, {:array, :string}, null: false, default: []
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:skills, [:name])

    # Where each skill is on: "blip", or a project's ID. A string rather
    # than a foreign key, so Blip and projects share the table.
    create table(:skill_enablements, primary_key: false) do
      add :skill_id, references(:skills, type: :string, on_delete: :delete_all), null: false
      add :scope, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:skill_enablements, [:scope, :skill_id])
    create index(:skill_enablements, [:skill_id])
  end
end
