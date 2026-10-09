defmodule Photon.Repo.Migrations.DigestItemsCarried do
  use Ecto.Migration

  # Ambient mode's digest items: an item a posted digest carries stays until
  # Blip's run on that digest settles, so a run that fails gives it back;
  # and a stopped schedule's item names the task that failed, so a schedule
  # saved again since is no longer news.
  def change do
    alter table(:digest_items) do
      # The key of the digest that carries the item, or nil while it waits.
      add :digest_key, :string
      # A "schedule_stopped" item's failed routine task.
      add :task_id, :string
    end

    create index(:digest_items, [:digest_key])
  end
end
