defmodule Photon.Application do
  @moduledoc """
  Starts the hub. The supervision tree, in start order (each child needs
  only the ones before it):

    * `PhotonWeb.Telemetry`: metrics
    * `Photon.Repo` and `Ecto.Migrator` (migrates at boot, then exits
      normally): the SQLite database
    * `Photon.PubSub`: every change notification below goes through it
    * `Photon.Tailnet`: owns the tailnet lookup cache (an ETS table)
    * `Photon.MachineRegistry`: machine ID to its node's channel process,
      so "online" means "its channel is alive" and nothing keeps a pid
    * `Photon.ProvisionTasks` and `Photon.Provision`: SSH jobs, and the
      table of jobs that monitors them
    * `Photon.ChatGPT`: the ChatGPT account (Sign in with ChatGPT), which
      holds the tokens and refreshes them one at a time
    * `Photon.Durable.Supervisor`: the durable harness Blip and threads
      run on, and whose waiting tasks are the schedules' and ambient
      mode's timers (left out with `config :photon, start_durable: false`,
      as in tests); see its moduledoc for its own plan
    * `PhotonWeb.Endpoint`: HTTP, LiveViews and the node websocket. It
      starts after everything pages and channels call, and stops first.
    * `PhotonNode` (with `config :photon, local_node: true`): a node inside
      this VM, last because it dials the endpoint

  The strategy is `:one_for_one`: each child recovers on its own. The
  per-connection processes (node channels and LiveViews) live under the
  endpoint and find what they need by name, and durable work is in the
  database, so a restarted child doesn't need its neighbours restarted.
  The exceptions are the library processes `Photon.PubSub` and
  `Photon.MachineRegistry`, whose subscribers and registrations a restart
  would drop; they are not expected to crash, and the strategy is kept as
  it was rather than restart the web layer with them. Shutdown runs in
  reverse: the local node and the endpoint stop before the durable harness,
  so nothing new arrives while it stops.

  Projects, threads, skills, schedules, questions, signals, ambient mode
  and the activity log add no process here: they are rows behind their
  contexts' APIs, threads run on the durable harness, a schedule and each
  of ambient mode's two timers wait as durable tasks, a thread waiting on
  Blip's answer is its parked tool task, and a signal (a digest or a
  daily review included) is a message in Blip's conversation. So a hub
  restart finds every schedule, timer, pending digest item and open
  question where it was.
  """

  use Boundary, top_level?: true, deps: [Photon, PhotonWeb, PhotonNode]

  use Application

  @impl true
  def start(_type, _args) do
    # Generated (and logged) at boot, not on the first sign-in.
    _password =
      if Photon.Auth.mode() in [:password, :tailscale_or_password],
        do: Photon.Auth.ensure_password!()

    children =
      [
        PhotonWeb.Telemetry,
        Photon.Repo,
        {Ecto.Migrator,
         repos: [Photon.Repo], skip: Application.get_env(:photon, :skip_migrations, false)},
        {Phoenix.PubSub, name: Photon.PubSub},
        Photon.Tailnet,
        {Registry, keys: :unique, name: Photon.MachineRegistry},
        {Task.Supervisor, name: Photon.ProvisionTasks},
        Photon.Provision,
        Photon.ChatGPT
      ] ++ durable() ++ [PhotonWeb.Endpoint] ++ local_node()

    opts = [strategy: :one_for_one, name: Photon.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The durable harness. Tests start it themselves, inside the sandbox.
  defp durable do
    if Application.get_env(:photon, :start_durable, true),
      do: [Photon.Durable.Supervisor],
      else: []
  end

  # A node inside this BEAM, connecting over the same websocket as remote
  # nodes: handy in development. Its operation journal lives in the data
  # directory, so its operations resume when the hub restarts.
  defp local_node do
    if Application.get_env(:photon, :local_node) do
      http = Application.get_env(:photon, PhotonWeb.Endpoint)[:http]

      [
        {PhotonNode,
         server: "ws://#{local_address(http[:ip])}:#{http[:port]}/node/websocket",
         token: Photon.NodeKeys.local_token(),
         node_id: "local",
         data_dir: Photon.Paths.local_node_dir()}
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
