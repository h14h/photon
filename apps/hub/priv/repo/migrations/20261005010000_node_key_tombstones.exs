defmodule Photon.Repo.Migrations.NodeKeyTombstones do
  use Ecto.Migration

  def change do
    alter table(:node_keys) do
      # A removed node's row stays, without a usable key, so its machine
      # stays out of the GUI until the user lets it back in.
      add :revoked_at, :utc_datetime_usec
    end

    # Keys made before untied keys expired, and still untied, expire now.
    now = DateTime.to_iso8601(DateTime.utc_now())

    execute(
      "UPDATE node_keys SET expires_at = '#{now}' WHERE device IS NULL AND expires_at IS NULL",
      ""
    )
  end
end
