defmodule Photon.Repo.Migrations.NodeKeyGenerations do
  use Ecto.Migration

  def change do
    alter table(:node_keys) do
      # Bumped on every new key, so connections made with an older one can
      # be told apart and dropped.
      add :generation, :integer, null: false, default: 0
      # When a key made for a machine nobody has named yet stops working if
      # still unused.
      add :expires_at, :utc_datetime_usec
    end
  end
end
