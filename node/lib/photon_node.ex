defmodule PhotonNode do
  @moduledoc """
  A headless Photon node: runs `unreal-agent-runner` processes on this machine
  and streams their events to a Photon GUI server over a websocket.

  The node dials the server (so it works behind NAT) and joins the channel
  `"node:<node_id>"`. The protocol, as seen from the node:

    * join params: static info (`hostname`, `platform`, `runner`, `workspace`,
      `key_envs`, `version`)
    * join reply: `%{"sync" => %{session_id => offset}}`, the number of events
      the server already holds for each session it has assigned to this node.
      The node replays everything past those offsets, then pushes `status`.
    * node → server: `event` (`session_id`, `offset`, `event`), `run_started`,
      `run_finished` (`session_id`, `status`), `status` (`running`)
    * server → node: `start_run` (`session_id`, `prompt`, `config`,
      `attachments`: `[%{"path", "data" (base64)}]`),
      `stop_run`, `delete_session`, `resync` (`session_id`, `from`)

  Offsets index each session's event log on the node, so delivery is
  idempotent: the server drops offsets it has seen and asks for a resync when
  it notices a gap. Runs keep going while disconnected and catch up on reconnect.

  Start it with `{PhotonNode, opts}` in a supervision tree, or let the
  `:photon_node` application start it from config (see `PhotonNode.Config`).
  """

  use Supervisor

  alias PhotonNode.Config

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    config = Config.new(opts)
    :persistent_term.put({__MODULE__, :config}, config)

    children = [
      {Registry, keys: :unique, name: PhotonNode.RunRegistry},
      {DynamicSupervisor, name: PhotonNode.RunSupervisor, strategy: :one_for_one},
      PhotonNode.EventLog,
      PhotonNode.Connection
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc "The running node's configuration."
  def config, do: :persistent_term.get({__MODULE__, :config})
end
