defmodule Photon.Repo do
  @moduledoc """
  The hub's SQLite database (`<data dir>/photon.db`): the assistant's durable
  state (`Photon.Durable`), the operations it runs on machines
  (`Photon.Machines`) and the node keys (`Photon.NodeKeys`).
  """

  use Boundary, deps: []

  use Ecto.Repo, otp_app: :photon, adapter: Ecto.Adapters.SQLite3
end
