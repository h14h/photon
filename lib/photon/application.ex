defmodule Photon.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    if Photon.Auth.enabled?(), do: Photon.Auth.ensure_password!()

    children =
      [
        PhotonWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:photon, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Photon.PubSub},
        Photon.Sessions.Counts,
        Photon.Tailnet,
        {Registry, keys: :unique, name: Photon.NodeRegistry},
        {Task.Supervisor, name: Photon.ProvisionTasks},
        Photon.Provision,
        PhotonWeb.Endpoint
      ] ++ local_node()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Photon.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # An agent node inside this BEAM, connecting over the same websocket as
  # remote nodes. Its runs stop if the server stops; run the `node/` project
  # separately (with PHOTON_LOCAL_NODE=false) for runs that outlive restarts.
  defp local_node do
    if Application.get_env(:photon, :local_node) do
      http = Application.get_env(:photon, PhotonWeb.Endpoint)[:http]

      [
        {PhotonNode,
         server: "ws://#{local_address(http[:ip])}:#{http[:port]}/node/websocket",
         token: Photon.NodeAuth.token(),
         node_id: "local",
         data_dir: Photon.Paths.data_dir(),
         workspace: Photon.Paths.default_workspace()}
      ]
    else
      []
    end
  end

  # The embedded node dials whatever address the endpoint listens on.
  defp local_address(ip) when ip in [nil, {0, 0, 0, 0}], do: "127.0.0.1"
  defp local_address({0, 0, 0, 0, 0, 0, 0, 0}), do: "[::1]"
  defp local_address({_, _, _, _} = ip), do: ip |> :inet.ntoa() |> to_string()
  defp local_address(ip), do: "[#{ip |> :inet.ntoa() |> to_string()}]"

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PhotonWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
