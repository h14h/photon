defmodule Photon.Repo do
  @moduledoc """
  The hub's SQLite database (`<data dir>/photon.db`): the assistant's durable
  state (`Photon.Durable`) and the hub's copy of every node session.
  """

  use Boundary, deps: []

  use Ecto.Repo, otp_app: :photon, adapter: Ecto.Adapters.SQLite3
end
