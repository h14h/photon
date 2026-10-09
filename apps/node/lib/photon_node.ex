defmodule PhotonNode do
  @moduledoc """
  A Photon node: runs the hub's operations (shell commands, image reads)
  on this machine. It dials the hub's websocket (so it works behind NAT)
  and joins `"node:<node_id>"` with `hostname`, `platform`, `workspace`,
  `version` and `capabilities`; the hub sends operations only to a node
  that lists `PhotonCore.Operation.Wire.capability/0`. `Wire` has the
  messages and `docs/operations.md` the rules.

  Start it with `{PhotonNode, opts}` in a supervision tree, or let the
  `:photon_node` application start it from config (see `PhotonNode.Config`).

  ## Supervision

  This module is the node's supervisor, `:rest_for_one`, since each child
  depends on the ones before it:

    * `PhotonNode.OpRegistry`: names operation processes by ID, so nothing
      holds on to their pids
    * `PhotonNode.OpSupervisor`: one `:temporary` process per running
      operation (`PhotonNode.Ops`). A crash isn't restarted here; the
      executor monitors its operations and decides.
    * `PhotonNode.Executor` (`:permanent`): recovers from its journal on
      start (see it). The operation processes keep running while it is
      down, and their calls into it return at once.
    * `PhotonNode.Connection` (`:permanent`, left out with `connect:
      false`): a restart loses nothing durable, since it resends the
      journal's snapshots after it rejoins.

  A crashed registry or supervisor takes everything after it down and back
  up in order, and the executor resumes the operations from the journal,
  as after a node VM restart (a shell command's outcome then comes from
  its files; see `PhotonNode.Ops.Shell`). Shutdown runs in reverse, so the
  executor stops before the operations, and a shell operation kills its
  command's process group as it stops (node rule 10). Workers use the
  default 5 second shutdown, supervisors `:infinity`.

  The config sits in `:persistent_term` (`config/0`) and every name is
  global, so a VM runs at most one node.
  """

  # The node; its layers are boundaries inside this one.
  use Boundary, deps: [PhotonCore, Jason, Slipstream], exports: []

  use Supervisor

  alias PhotonNode.Config

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    config = Config.new(opts)
    :persistent_term.put({__MODULE__, :config}, config)
    File.mkdir_p!(Config.ops_dir(config))
    File.mkdir_p!(config.workspace)

    children = [
      {Registry, keys: :unique, name: PhotonNode.OpRegistry},
      {DynamicSupervisor, name: PhotonNode.OpSupervisor, strategy: :one_for_one},
      PhotonNode.Executor,
      connection(opts)
    ]

    Supervisor.init(Enum.reject(children, &is_nil/1), strategy: :rest_for_one)
  end

  # Tests run the node without a hub.
  defp connection(opts), do: if(Keyword.get(opts, :connect, true), do: PhotonNode.Connection)

  @doc "The running node's configuration."
  @spec config() :: Config.t()
  def config, do: :persistent_term.get({__MODULE__, :config})
end
