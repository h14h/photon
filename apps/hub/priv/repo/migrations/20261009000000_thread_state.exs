defmodule Photon.Repo.Migrations.ThreadState do
  use Ecto.Migration

  # The facts a thread's state is worked out from (section 2.1 of
  # `docs/plans/step-4-blip-as-coordinator.md`): who started it, how its
  # last run ended, and when the owner last looked at it or resolved it.
  def change do
    alter table(:threads) do
      add :started_by, :string, null: false, default: "owner"
      add :last_run_status, :string
      add :last_run_ended_at, :utc_datetime_usec
      add :last_run_asked, :boolean, null: false, default: false
      add :last_run_note, :string
      add :seen_at, :utc_datetime_usec
      add :resolved_at, :utc_datetime_usec
    end
  end
end
