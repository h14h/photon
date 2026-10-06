defmodule Photon.Nodes do
  @moduledoc """
  Agent nodes currently connected to this hub.

  Each node is represented by its `PhotonWeb.NodeChannel` process, which
  registers itself with `register/2`: an entry in `Photon.NodeRegistry`
  under the node ID, with the node's info as the registry value. So a node
  is online exactly as long as its channel lives, and nothing here holds on
  to a pid. The registry is this module's; callers name nodes by ID.

  Commands are fire-and-forget: `command/3` sends the channel process a
  message, and results come back as session records. A plain send on
  purpose: the caller (a tool step, a LiveView, the session outbox) must not
  wait on a node's connection, and every command it sends is small and
  bounded by what a user or the assistant does. A command lost with a
  dropping connection is recovered where it matters: inputs stay queued in
  `Photon.NodeSessions`'s outbox and are resent on the next join. A stop is
  not resent.

  `push_op/2` is the same kind of send for operations: it asks the channel
  to push an op, and the channel builds the `op.start` from the op's row
  (`Photon.Machines.push_for/2`), so only `Photon.Machines` calls it. Ops
  are rows, pushed again on every join and every minute while their call
  waits on an online machine, so a lost request costs a delay, not the op.
  """

  use Boundary, deps: [Photon.Events]

  require Logger

  alias Photon.Events

  @topic "nodes"
  @takeover_timeout 2_000

  @typedoc "A connected node's info, with its `\"id\"`."
  @type info :: %{optional(String.t()) => term()}

  @doc "PubSub topic carrying `:nodes_changed` whenever a node joins, leaves or changes state."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribes to `:nodes_changed`."
  @spec subscribe() :: :ok
  def subscribe, do: Events.subscribe(@topic)

  @spec broadcast() :: :ok
  def broadcast, do: Events.broadcast(@topic, :nodes_changed)

  @doc "Connected nodes, sorted by ID."
  @spec list() :: [info()]
  def list do
    Photon.NodeRegistry
    |> Registry.select([{{:"$1", :_, :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {id, info} -> Map.put(info, "id", id) end)
    |> sort()
  end

  @doc false
  # The local node first, then by ID.
  @spec sort([info()]) :: [info()]
  def sort(nodes), do: Enum.sort_by(nodes, &{&1["id"] != "local", &1["id"]})

  @spec get(String.t()) :: info() | nil
  def get(id) do
    case Registry.lookup(Photon.NodeRegistry, id) do
      [{_pid, info}] -> Map.put(info, "id", id)
      [] -> nil
    end
  end

  @spec online?(String.t()) :: boolean()
  def online?(id), do: get(id) != nil

  @doc """
  Every node worth listing: the connected ones (`online`, from `list/0`),
  then the IDs of nodes that only appear in `sessions`, offline. Pure.
  """
  @spec roster([info()], [Photon.NodeSessions.Session.t()]) :: [
          %{id: String.t(), online: boolean(), info: info() | nil}
        ]
  def roster(online, sessions) do
    online_ids = MapSet.new(online, & &1["id"])

    offline =
      sessions
      |> Enum.map(& &1.node_id)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(online_ids, &1))

    Enum.map(online, &%{id: &1["id"], online: true, info: &1}) ++
      Enum.map(offline, &%{id: &1, online: false, info: nil})
  end

  @doc """
  Registers the calling process as the connection for `node_id`, with the
  node's `info`. A previous connection still registered for the node (it
  reconnected before the old one timed out) is told to stop (`:replaced`)
  and given two seconds before it is killed, so the registry never names two
  connections for one node.
  """
  @spec register(String.t(), info()) :: :ok
  def register(node_id, info) do
    take_over(node_id)
    {:ok, _owner} = Registry.register(Photon.NodeRegistry, node_id, info)
    :ok
  end

  @doc "Removes the calling process's registration as `node_id`'s connection."
  @spec unregister(String.t()) :: :ok
  def unregister(node_id), do: Registry.unregister(Photon.NodeRegistry, node_id)

  defp take_over(node_id) do
    case Registry.lookup(Photon.NodeRegistry, node_id) do
      [{pid, _}] -> replace(node_id, pid)
      [] -> :ok
    end
  end

  defp replace(node_id, pid) do
    Logger.warning("node #{node_id} reconnected; closing its previous connection")
    ref = Process.monitor(pid)
    send(pid, :replaced)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    after
      @takeover_timeout -> Process.exit(pid, :kill)
    end
  end

  @doc "Pushes a command to a connected node; `{:error, :offline}` otherwise."
  @spec command(String.t(), String.t(), map()) :: :ok | {:error, :offline}
  def command(node_id, event, payload), do: tell(node_id, {:command, event, payload})

  @doc """
  Asks a connected node's channel to push op `op_id`, built from its row as
  it is then; `{:error, :offline}` if the node isn't connected.
  """
  @spec push_op(String.t(), String.t()) :: :ok | {:error, :offline}
  def push_op(node_id, op_id), do: tell(node_id, {:push_op, op_id})

  defp tell(node_id, message) do
    case Registry.lookup(Photon.NodeRegistry, node_id) do
      [{pid, _}] ->
        send(pid, message)
        :ok

      [] ->
        {:error, :offline}
    end
  end
end
