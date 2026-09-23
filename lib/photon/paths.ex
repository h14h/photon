defmodule Photon.Paths do
  @moduledoc "Filesystem locations used by the playground."

  def data_dir, do: Application.fetch_env!(:photon, :data_dir) |> Path.expand()

  def settings_file, do: Path.join(data_dir(), "settings.json")
  def sessions_dir, do: Path.join(data_dir(), "sessions")
  def node_token_file, do: Path.join(data_dir(), "node-token")

  # The embedded local node shares the data directory, so its runner session
  # store and workspace sit where they did before nodes existed.
  def default_workspace, do: Path.join(data_dir(), "workspace")
end
