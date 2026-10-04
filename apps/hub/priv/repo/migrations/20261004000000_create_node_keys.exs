defmodule Photon.Repo.Migrations.CreateNodeKeys do
  use Ecto.Migration

  def change do
    create table(:node_keys, primary_key: false) do
      add :node_id, :string, primary_key: true
      add :key_hash, :binary, null: false
      add :device, :string
      add :device_name, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:node_keys, [:key_hash])
  end
end
