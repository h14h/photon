defmodule Photon.Repo.Migrations.MachineOpOutput do
  use Ecto.Migration

  # What a command printed before its call was stopped (or otherwise ended
  # without its result), kept so the conversation still shows it after a
  # reload; the live output is never stored. Read by conversation.
  def change do
    alter table(:machine_ops) do
      add :output, :text
    end

    create index(:machine_ops, [:conversation_id])
  end
end
