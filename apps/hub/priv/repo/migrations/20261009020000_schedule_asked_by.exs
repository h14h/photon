defmodule Photon.Repo.Migrations.ScheduleAskedBy do
  use Ecto.Migration

  # Why one of Blip's schedules was made: "owner" when the owner wrote to
  # the run that made it, "blip" when Blip set it up on its own. Nil for the
  # schedules the owner makes on a project's page.
  def change do
    alter table(:schedules) do
      add :asked_by, :string
    end
  end
end
