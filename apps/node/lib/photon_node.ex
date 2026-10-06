defmodule PhotonNode do
  @moduledoc """
  A Photon node: runs the hub's operations (shell commands, image reads)
  on this machine with `PhotonNode.Executor`, over a websocket to a Photon
  hub.

  The node dials the hub (so it works behind NAT) and joins the channel
  `"node:<node_id>"` with static info about itself (`hostname`,
  `platform`, `workspace`, `version`, `capabilities`); `capabilities` is
  `["ops:2"]`: the operation protocol, where a `shell` operation creates
  its working directory when it is missing (`ops:1` didn't). The hub
  sends no operations to a node that doesn't list `ops:2`.

  Start it with `{PhotonNode, opts}` in a supervision tree, or let the
  `:photon_node` application start it from config (see `PhotonNode.Config`).

  ## The operation protocol

  `PhotonCore.Operation.Wire` builds and parses its messages;
  `docs/plans/step-1-machine-tools.md`, section 2, has its rules. As seen
  from the node:

    * hub → node: `op.start` (`id`, `kind`, `args`, `known`): run this
      operation, or send its latest snapshot if the node has it; `op.cancel`
      (`id`): stop it and never start it; `op.ack` (`id`): the hub has
      recorded its result, so the node may forget it
    * node → hub: `op.snapshot` (`op`): an operation's latest snapshot,
      journaled first, a terminal one being its result; `op.output` (`id`,
      `stream`, `text`): new command output, never stored
    * after every join the node sends the snapshot of every operation in its
      journal, and the hub sends `op.start` or `op.cancel` for the
      operations it still waits on

  The executor journals each operation before it runs and every snapshot
  before it is sent, so a lost message is recovered by the next join, a
  repeated `op.start` never runs a command twice, and an operation keeps
  running while the hub is unreachable. Unknown events and fields are
  ignored, so either side can be updated first.

  ## Lifecycle

  This module is the node's supervisor. Its children, in start order, with
  `:rest_for_one`, because each depends on the ones before it:

    * `PhotonNode.OpRegistry`: a unique registry that names operation
      processes by ID, so nothing holds on to their pids
    * `PhotonNode.OpSupervisor`: one `:temporary` process per running
      operation, started by `PhotonNode.Ops.add/2` for its owner
      (`PhotonNode.Ops.Owner`), the executor. A crash is not restarted
      here; the executor monitors its operations and decides. A shell
      stopped here while its command runs kills the command and leaves a
      `stopped` marker, so a resumed operation says so.
    * `PhotonNode.Executor` (`:permanent`): the hub's operations, one
      process for all of them, with their journal in `<data_dir>/ops`. On
      start it scans the journal: operations still running are monitored
      again and asked to resend their snapshots, unfinished ones nothing
      runs are resumed from their snapshots, and either is told to cancel
      if its journal says so. A crash restarts it and the connection after
      it; it loses only its monitors and restart counts, which the scan
      rebuilds. The operation processes keep running, and their calls into
      it return at once until it is back.
    * `PhotonNode.Connection` (`:permanent`, left out with `connect:
      false`): the hub link. A crash restarts only the connection, which
      loses nothing durable: it sends the journal's snapshots after it
      rejoins.

  A crashed registry or supervisor takes everything after it down with it
  and back up in order: the executor restarts after the operations it
  tracks and resumes them from the journal. A node VM restart does the
  same, and a shell command's outcome then comes from its `canceled`,
  `stopped`, `exit`, `pid` and `unstarted` files. Shutdown runs in
  reverse, so the executor stops before the operations, and a shell
  operation kills its command's process group as it stops (and leaves its
  `stopped` marker, so the restarted node reports the command as killed). Workers use the
  default 5 second shutdown, supervisors `:infinity`.

  The config sits in `:persistent_term` (`config/0`) and every name is
  global, so a VM runs at most one node.
  """

  # The node: this supervisor (and the config accessor), with the operation
  # layer, the executor, its hub connection, the config and the CLI as
  # boundaries inside it.
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
