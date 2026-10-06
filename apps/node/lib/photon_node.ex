defmodule PhotonNode do
  @moduledoc """
  A Photon node: runs agent sessions on this machine with
  `PhotonNode.Harness` and mirrors them to a Photon hub over a websocket,
  and runs the hub's operations (shell commands, image reads) with
  `PhotonNode.Executor`.

  The node dials the hub (so it works behind NAT) and joins the channel
  `"node:<node_id>"`, which carries two protocols. Both share the join
  params, static info about the node (`hostname`, `platform`, `workspace`,
  `version`, `capabilities`); `capabilities` lists `"harness:1"` for
  sessions and `"ops:1"` for operations.

  Start it with `{PhotonNode, opts}` in a supervision tree, or let the
  `:photon_node` application start it from config (see `PhotonNode.Config`).

  ## Sessions

  The session protocol, as seen from the node:

    * join reply: `%{"sync" => %{session_id => offset}}`, how many records of
      each session's log the hub already holds. The node replays everything
      past those offsets.
    * node → hub: `event` (`session_id`, `offset`, `event`: one log record),
      `live` (`session_id`, `data`): streaming model text and command
      output, which is never stored, and `input_rejected` (`session_id`,
      `input_id`, `reason`): an input the node refused (invalid, or for a
      session it can't create or start)
    * hub → node: `input` (`session_id`, `input`, `config`), `stop`
      (`session_id`), `delete_session` (`session_id`), `resync`
      (`session_id`, `from`)

  Offsets index each session's log, so delivery is idempotent: the hub drops
  offsets it has seen and asks for a resync when it notices a gap. Inputs
  carry IDs and the harness drops repeats, so the hub can resend any input
  it isn't sure arrived. The node handles an `input` only once it is in the
  session's log (or known as a repeat), retrying with a restarted
  coordinator if needed, so an input is never lost on the node while the
  connection holds. The hub pushes each input once per connection, only
  while it is still queued, and resends queued inputs on every join.
  Sessions keep working while the hub is unreachable (model requests retry)
  and catch up on reconnect.

  ## Operations

  The operation protocol (`PhotonCore.Operation.Wire` builds and parses its
  messages; `docs/plans/step-1-machine-tools.md`, section 2, has its
  rules), as seen from the node:

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
  running while the hub is unreachable.

  ## Lifecycle

  This module is the node's supervisor. Its children, in start order, with
  `:rest_for_one`, because each depends on the ones before it:

    * `PhotonNode.SessionRegistry` and `PhotonNode.OpRegistry`: unique
      registries that name session coordinators and operation processes by
      ID, so nothing holds on to their pids
    * `PhotonNode.Harness.TaskSupervisor`: model request tasks, each linked
      to the coordinator that started it
    * `PhotonNode.Harness.OpSupervisor`: one `:temporary` process per
      running operation, started by `PhotonNode.Harness.Ops.add/2` for an
      owner (`PhotonNode.Harness.Ops.Owner`). A crash is not restarted
      here; the owner (a session's coordinator, or the executor for the
      hub's operations) monitors its operations and decides. A shell
      stopped here while its command runs kills the command and leaves a
      `stopped` marker, so a resumed operation says so.
    * `PhotonNode.Harness.SessionSupervisor`: one `:transient` coordinator
      per active session, started on demand by
      `PhotonNode.Harness.Coordinator.ensure_started/1`. It stops itself
      after ten idle minutes and replays its log when started again.
    * `PhotonNode.Executor` (`:permanent`): the hub's operations, one
      process for all of them, with their journal in `<data_dir>/ops`. On
      start it scans the journal: operations still running are monitored
      again and asked to resend their snapshots, unfinished ones nothing
      runs are resumed from their snapshots, and either is told to cancel
      if its journal says so. A crash restarts it and the connection after
      it; the operation processes keep running, and their calls into it
      return at once until it is back.
    * `PhotonNode.Connection` (`:permanent`, left out with `connect:
      false`): the hub link. A crash restarts only the connection, which
      replays session records and sends the journal's snapshots after it
      rejoins.
    * `:resume` (`:temporary`): a one-shot task that starts the
      coordinators of sessions that were working when the node stopped.

  A crashed registry or supervisor takes everything after it down with it
  and back up in order: coordinators and the executor restart after the
  operations they track, and resume from their logs and the journal.
  Shutdown runs in reverse, so coordinators and the executor stop before
  the operations, and a shell operation kills its command's process group
  as it stops (and leaves its `stopped` marker, so the restarted node
  reports the command as killed). Workers use the default 5 second
  shutdown, supervisors `:infinity`.

  The config sits in `:persistent_term` (`config/0`) and every name is
  global, so a VM runs at most one node.
  """

  # The node: this supervisor (and the config accessor), with the harness,
  # its hub connection, the config and the CLI as boundaries inside it.
  use Boundary,
    deps: [PhotonCore, PhotonCore.LLM, PhotonCore.LLM.Error, Jason, Slipstream],
    exports: []

  use Supervisor

  alias PhotonNode.Config

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    config = Config.new(opts)
    :persistent_term.put({__MODULE__, :config}, config)
    File.mkdir_p!(Config.sessions_dir(config))
    File.mkdir_p!(Config.ops_dir(config))
    File.mkdir_p!(config.workspace)

    children = [
      {Registry, keys: :unique, name: PhotonNode.SessionRegistry},
      {Registry, keys: :unique, name: PhotonNode.OpRegistry},
      {Task.Supervisor, name: PhotonNode.Harness.TaskSupervisor},
      {DynamicSupervisor, name: PhotonNode.Harness.OpSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: PhotonNode.Harness.SessionSupervisor, strategy: :one_for_one},
      PhotonNode.Executor,
      connection(opts),
      Supervisor.child_spec({Task, &PhotonNode.Harness.resume_all/0},
        id: :resume,
        restart: :temporary
      )
    ]

    Supervisor.init(Enum.reject(children, &is_nil/1), strategy: :rest_for_one)
  end

  # Tests run the harness without a hub.
  defp connection(opts), do: if(Keyword.get(opts, :connect, true), do: PhotonNode.Connection)

  @doc "The running node's configuration."
  @spec config() :: Config.t()
  def config, do: :persistent_term.get({__MODULE__, :config})
end
