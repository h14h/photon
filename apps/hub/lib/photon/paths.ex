defmodule Photon.Paths do
  @moduledoc "Filesystem locations the hub uses, all under its data directory."

  use Boundary, deps: []

  @spec data_dir() :: Path.t()
  def data_dir, do: Path.expand(Application.fetch_env!(:photon, :data_dir))

  @spec settings_file() :: Path.t()
  def settings_file, do: Path.join(data_dir(), "settings.json")
  @doc "The ChatGPT account: the hub's host ID, its client ID and the tokens (mode 0600)."
  @spec chatgpt_file() :: Path.t()
  def chatgpt_file, do: Path.join(data_dir(), "chatgpt.json")

  # The embedded local node (development) keeps its sessions here too.
  @spec local_node_dir() :: Path.t()
  def local_node_dir, do: Path.join(data_dir(), "local-node")
end
