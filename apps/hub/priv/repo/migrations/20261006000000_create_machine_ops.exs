defmodule Photon.Repo.Migrations.CreateMachineOps do
  use Ecto.Migration

  def change do
    create table(:machine_ops, primary_key: false) do
      add :id, :string, primary_key: true
      add :machine, :string, null: false
      add :kind, :string, null: false
      add :args, :map, null: false
      add :conversation_id, :string
      add :call_id, :string
      add :task_id, :string, null: false
      add :status, :string, null: false
      add :confirmed, :boolean, null: false, default: false
      add :pushed, :boolean, null: false, default: false
      add :cancel, :boolean, null: false, default: false
      add :result, :map
      timestamps(type: :utc_datetime_usec)
    end

    create index(:machine_ops, [:machine, :status])
  end
end
