defmodule Photon.Repo.Migrations.CreateActivity do
  use Ecto.Migration

  # The activity log: one row per tool call Blip made, and per message it
  # told the owner unasked, written once in the commit that stored it. No
  # foreign keys: the log outlives what it names.
  def change do
    create table(:activity, primary_key: false) do
      add :id, :string, primary_key: true
      # "call" (a tool call) or "message" (Blip told the owner something).
      add :kind, :string, null: false
      # The tool's name; nil for a message.
      add :tool, :string
      add :summary, :string, null: false
      # The result's status: "ok", "error", "interrupted" or "aborted".
      add :status, :string, null: false
      add :changes, :boolean, null: false
      # "owner", "thread", "schedule", "follow_up" or "unknown".
      add :origin, :string, null: false
      add :origin_id, :string
      add :project_id, :string
      add :thread_id, :string
      # The tool_result entry, or the answer entry for a message, in Blip's
      # conversation.
      add :entry_id, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:activity, [:entry_id])
    create index(:activity, [:inserted_at])
    create index(:activity, [:origin, :inserted_at])
  end
end
