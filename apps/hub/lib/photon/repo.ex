defmodule Photon.Repo do
  @moduledoc "The hub's SQLite database (`<data dir>/photon.db`)."

  use Boundary, deps: []

  use Ecto.Repo, otp_app: :photon, adapter: Ecto.Adapters.SQLite3
end
