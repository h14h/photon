defmodule Photon.Repo.Migrations.CreateProjects do
  use Ecto.Migration

  def change do
    create table(:projects, primary_key: false) do
      add :id, :string, primary_key: true
      add :slug, :string, null: false
      add :name, :string, null: false
      add :purpose, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:projects, [:slug])

    create table(:project_files, primary_key: false) do
      add :id, :string, primary_key: true

      add :project_id, references(:projects, type: :string, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :key, :string, null: false
      add :content, :text, null: false
      add :version, :integer, null: false
      add :updated_by, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:project_files, [:project_id, :key])
  end
end
