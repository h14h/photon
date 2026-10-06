defmodule PhotonNode do
  @moduledoc """
  A Photon node: runs agent sessions on this machine with
  `PhotonNode.Harness` and mirrors them to a Photon hub over a websocket.

  The node dials the hub (so it works behind NAT) and joins the channel
  `"node:<node_id>"`. The protocol, as seen from the node:

    * join params: static info (`hostname`, `platform`, `workspace`,
      `version`, `capabilities`)
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

  Start it with `{PhotonNode, opts}` in a supervision tree, or let the
  `:photon_node` application start it from config (see `PhotonNode.Config`).

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
      here; the owner, a session's coordinator, monitors its operations
      and decides. A shell stopped here while its command runs kills the
      command and leaves a `stopped` marker, so a resumed operation says so.
    * `PhotonNode.Harness.SessionSupervisor`: one `:transient` coordinator
      per active session, started on demand by
      `PhotonNode.Harness.Coordinator.ensure_started/1`. It stops itself
      after ten idle minutes and replays its log when started again.
    * `PhotonNode.Connection` (`:permanent`, left out with `connect:
      false`): the hub link. A crash restarts only the connection, which
      replays to the hub after it rejoins.
    * `:resume` (`:temporary`): a one-shot task that starts the
      coordinators of sessions that were working when the node stopped.

  A crashed registry or supervisor takes everything after it down with it
  and back up in order: coordinators restart after the operations they
  track, and resume from their logs. Shutdown runs in reverse, so
  coordinators stop before the operations, and a shell operation kills its
  command's process group as it stops. Workers use the default 5 second
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
    File.mkdir_p!(config.workspace)

    children = [
      {Registry, keys: :unique, name: PhotonNode.SessionRegistry},
      {Registry, keys: :unique, name: PhotonNode.OpRegistry},
      {Task.Supervisor, name: PhotonNode.Harness.TaskSupervisor},
      {DynamicSupervisor, name: PhotonNode.Harness.OpSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: PhotonNode.Harness.SessionSupervisor, strategy: :one_for_one},
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
