defmodule PhotonNode.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    if PhotonNode.CLI.standalone?(), do: PhotonNode.CLI.boot()

    # When embedded in the GUI, the host starts `{PhotonNode, opts}` itself.
    children =
      if Application.get_env(:photon_node, :autostart, true), do: [{PhotonNode, []}], else: []

    Supervisor.start_link(children, strategy: :one_for_one, name: PhotonNode.AppSupervisor)
  end
end
