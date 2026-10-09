defmodule Photon.Machines do
  @moduledoc """
  Machines and the operations the hub runs on them: which machines exist and
  what state each is in, starting and cancelling an operation, and the
  reports a machine's channel hands over. `docs/operations.md` has the
  protocol's guarantees and rules.

  A machine is online exactly as long as its node's connection lives. Each
  connection is a `PhotonWeb.NodeChannel` process, which registers itself
  with `register/2`: an entry in `Photon.MachineRegistry` under the
  machine's ID, with the node's info as the registry value. Nothing here
  holds on to a pid; the registry is this module's, and callers name
  machines by ID. `list/0`, `get/1` and `online?/1` read it, and
  `subscribe/0` hears `:nodes_changed` whenever a node joins or leaves.
  The machines the hub knows but can't reach are the IDs of node keys that
  aren't revoked (`Photon.NodeKeys`), plus `local` when the hub runs its
  own node; `roster/0` and `status/1` combine the two. `known/0` lists the
  same machines by ID alone, `local` first and then by ID, an order that
  ignores who is connected: the agents' prompts list machine skills in it,
  so they change only when a machine is installed or removed, not when one
  connects or disconnects (`Photon.Machines.Roster.ids/3`).

  An operation is a row (`Photon.Machines.Op`, table `machine_ops`), one per
  tool call, keyed by the op ID the call derives from its durable task. The
  row is the hub's record of the op; the parked tool call waits on the
  signal `signal_key/1`, which fires in the commit that records the op's
  result.

  Every write goes through `Photon.Durable.Store` (`Photon.Durable.commit/1`):
  each function here reads the row inside a commit, asks
  `Photon.Machines.Rules` what to do, and applies the answer in the same
  commit. The channel's reads (`joined/1`, `push_for/2`) are commits too, so
  they wait for a commit in progress and record `pushed` on the rows they
  return an `op.start` for. Only the machine's channel puts an `op.start` on
  the wire, built from the row as it is when the channel pushes it: `start/1`
  and `repush/1` only ask the channel to push the op (`push_op/2`).

  Commands to a channel are plain sends, not calls: `push_op/2` and
  `command/3` send the channel process a message, and results come back as
  op snapshots. The caller (a tool step, or a commit) must not wait on a
  node's connection, and every command is small. Ops are rows, pushed again
  on every join and every minute while their call waits on an online
  machine, so a lost command costs a delay, not the op.

  Pushes come back as plain `{event, payload}` data, and the channel sends
  them after the commit returns, so an `op.ack` never leaves before the
  result is stored. The one exception is `op.cancel` from `cancel_tx/2` and
  `abandon_tx/2`: they run inside the caller's commit, read there whether
  the machine's channel is registered, and send it from inside (a node
  journals a cancel, so one sent by a commit that then rolls back is safe).

  Node payloads are parsed once, here, with `PhotonCore.Operation.Wire`;
  everything behind this module trusts them. A payload that doesn't parse
  is logged and dropped.

  Live output is never stored: `output/3` broadcasts each chunk to the tool
  call's conversation (`Photon.Durable.live/2`). The one exception is a
  call that ended another way (stopped, say): its row keeps the tail of
  what the op's final snapshot says the command printed
  (`stopped_outputs/1`), which is all there is to show of it after a
  reload. Which conversation and
  call an op belongs to is cached by the channel in a `t:routes/0` map, so
  a stream of output costs one read per op.

  There is no process here: the registry says who is connected, the rows
  hold the state, the durable harness waits, and the channel (one per
  connected machine) is the transport.
  """

  use Boundary,
    deps: [Photon.Durable, Photon.Events, Photon.NodeKeys, Photon.Repo, PhotonCore, Ecto],
    exports: []

  import Ecto.Query

  require Logger

  alias Photon.{Durable, Events, NodeKeys, Repo}
  alias Photon.Durable.Tx
  alias Photon.Machines.{Op, Roster, Rules}
  alias PhotonCore.Operation
  alias PhotonCore.Operation.Wire

  @topic "nodes"
  @takeover_timeout 2_000

  @typedoc "A connected machine's info, with its `\"id\"`."
  @type info :: Roster.info()

  @typedoc """
  A new op: its ID (from `t_<suffix>` to `op_<suffix>`), the machine,
  `kind` and `args` as `op.start` carries them, and the tool call it serves.
  """
  @type new :: %{
          required(:id) => String.t(),
          required(:machine) => String.t(),
          required(:kind) => String.t(),
          required(:args) => map(),
          required(:task_id) => String.t(),
          optional(:conversation_id) => String.t() | nil,
          optional(:call_id) => String.t() | nil
        }

  @typedoc "Where an op's live output goes: its conversation and call."
  @type route :: {String.t() | nil, String.t() | nil}

  @typedoc "A channel's cache of routes, by op ID; start it as `%{}`."
  @type routes :: %{optional(String.t()) => route()}

  @typedoc """
  What a tool call learns from its row: the result, if the op finished;
  whether the node has confirmed it, if it is still open; `:closed` once
  the result was claimed or the op was canceled; `:none` with no row.
  """
  @type op_state :: {:finished, Operation.t()} | {:open, boolean()} | :closed | :none

  @typedoc "What `abandon_tx/2` found: a result after all, or the facts for the offline message."
  @type abandoned :: {:claimed, Operation.t()} | {:abandoned, Rules.facts()}

  @doc "The signal that fires when op `op_id` has its result."
  @spec signal_key(String.t()) :: String.t()
  def signal_key(op_id), do: "op:" <> op_id

  ## Machines

  @doc "Subscribes to `:nodes_changed`, sent whenever a machine connects or disconnects."
  @spec subscribe() :: :ok
  def subscribe, do: Events.subscribe(@topic)

  @doc "Tells every subscriber that the connected machines changed."
  @spec broadcast() :: :ok
  def broadcast, do: Events.broadcast(@topic, :nodes_changed)

  @doc "Connected machines, `local` first, then by ID."
  @spec list() :: [info()]
  def list do
    Photon.MachineRegistry
    |> Registry.select([{{:"$1", :_, :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {id, info} -> Map.put(info, "id", id) end)
    |> Roster.sort()
  end

  @doc "A connected machine's info, or nil if it isn't connected."
  @spec get(String.t()) :: info() | nil
  def get(id) do
    case Registry.lookup(Photon.MachineRegistry, id) do
      [{_pid, info}] -> Map.put(info, "id", id)
      [] -> nil
    end
  end

  @doc "Whether `id` is connected now."
  @spec online?(String.t()) :: boolean()
  def online?(id), do: get(id) != nil

  @doc """
  Registers the calling process as the connection for `machine`, with the
  node's `info`. A previous connection still registered for the machine (it
  reconnected before the old one timed out) is told to stop (`:replaced`)
  and given two seconds before it is killed, so the registry never names two
  connections for one machine.
  """
  @spec register(String.t(), info()) :: :ok
  def register(machine, info) do
    take_over(machine)
    {:ok, _owner} = Registry.register(Photon.MachineRegistry, machine, info)
    :ok
  end

  @doc "Removes the calling process's registration as `machine`'s connection."
  @spec unregister(String.t()) :: :ok
  def unregister(machine), do: Registry.unregister(Photon.MachineRegistry, machine)

  defp take_over(machine) do
    case Registry.lookup(Photon.MachineRegistry, machine) do
      [{pid, _}] -> replace(machine, pid)
      [] -> :ok
    end
  end

  defp replace(machine, pid) do
    Logger.warning("#{machine} reconnected; closing its previous connection")
    ref = Process.monitor(pid)
    send(pid, :replaced)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    after
      @takeover_timeout -> Process.exit(pid, :kill)
    end
  end

  @doc """
  Pushes a command to a connected machine's channel; `{:error, :offline}`
  otherwise. Not for `op.start`, which only `push_op/2` asks for.
  """
  @spec command(String.t(), String.t(), map()) :: :ok | {:error, :offline}
  def command(machine, event, payload), do: tell(machine, {:command, event, payload})

  @doc """
  Asks a connected machine's channel to push op `op_id`, built from its row
  as it is then (`push_for/2`); `{:error, :offline}` if the machine isn't
  connected.
  """
  @spec push_op(String.t(), String.t()) :: :ok | {:error, :offline}
  def push_op(machine, op_id), do: tell(machine, {:push_op, op_id})

  defp tell(machine, message) do
    case Registry.lookup(Photon.MachineRegistry, machine) do
      [{pid, _}] ->
        send(pid, message)
        :ok

      [] ->
        {:error, :offline}
    end
  end

  @doc """
  The state of `machine`: `:online` (connected and speaks the operation
  protocol), `:outdated` (connected, but an older photon-node), `:offline`
  (known, not connected) or `:unknown`. `local` is known whenever the hub
  runs its own node (hub rule 12).
  """
  @spec status(String.t()) :: Roster.status()
  def status(machine), do: Roster.status(machine, get(machine), known_ids(), local_node?())

  @doc "Every machine the hub knows, `local` first, then connected ones, then offline ones."
  @spec roster() :: [Roster.machine()]
  def roster, do: Roster.build(list(), known_ids(), local_node?())

  @doc """
  The IDs of every machine the hub knows, connected or offline but not
  removed: `local` first, then by ID, whoever is connected.
  """
  @spec known() :: [String.t()]
  def known, do: Roster.ids(list(), known_ids(), local_node?())

  # Nodes with a key that hasn't been revoked.
  defp known_ids, do: for(%{node_id: id, revoked_at: nil} <- NodeKeys.list(), do: id)

  defp local_node?, do: Application.get_env(:photon, :local_node, false) == true

  ## Operations, for tool calls

  @doc """
  Records an op and asks its machine's channel to push it (hub rules 1, 2
  and 9). The row is inserted only while the tool task is unfinished and
  not marked for abort, and only once: a rerun finds the row and asks for
  the same op again. Returns `{:error, :stopped}`, with nothing inserted or
  pushed, when the task has ended or is being aborted.

  An offline machine gets the op when it joins.
  """
  @spec start(new()) :: :ok | {:error, :stopped}
  def start(%{id: id, machine: machine} = new) do
    if Durable.commit(&start_tx(&1, new)) do
      # Offline is fine: the machine's join pushes every open row.
      _ = push_op(machine, id)
      :ok
    else
      {:error, :stopped}
    end
  end

  defp start_tx(tx, new) do
    task = Tx.get_task(tx, new.task_id)

    if Rules.insert?(task && task.status, task != nil and task.abort_requested) do
      _row = Repo.insert!(row(new), on_conflict: :nothing, conflict_target: :id)
      true
    else
      false
    end
  end

  defp row(new) do
    %Op{
      id: new.id,
      machine: new.machine,
      kind: new.kind,
      args: new.args,
      task_id: new.task_id,
      conversation_id: new[:conversation_id],
      call_id: new[:call_id]
    }
  end

  @doc """
  Asks the op's machine to report it again (hub rule 11): its channel
  pushes `op.start` if the row is still open and not canceled. For a call
  that waits on an online machine, once a minute.
  """
  @spec repush(String.t()) :: :ok | {:error, :offline | :not_found}
  def repush(op_id) do
    case Repo.get(Op, op_id) do
      %Op{machine: machine} -> push_op(machine, op_id)
      nil -> {:error, :not_found}
    end
  end

  @doc "What the op's row says; see `t:op_state/0`."
  @spec op_state(String.t()) :: op_state()
  def op_state(op_id) do
    case Repo.get(Op, op_id) do
      %Op{status: "finished", result: snapshot} -> {:finished, snapshot}
      %Op{status: "open", confirmed: confirmed} -> {:open, confirmed}
      %Op{status: "closed"} -> :closed
      nil -> :none
    end
  end

  @doc """
  What the shell commands of conversation `conversation_id` printed before
  their calls ended another way (the user stopped them, say), by tool
  call ID: the output the rows kept from the ops' final snapshots
  (`Photon.Machines.Rules.output/1`). The conversation pages show it
  under a stopped call after a reload.
  """
  @spec stopped_outputs(String.t()) :: %{optional(String.t()) => String.t()}
  def stopped_outputs(conversation_id) do
    Op
    |> where(
      [o],
      o.conversation_id == ^conversation_id and not is_nil(o.call_id) and not is_nil(o.output)
    )
    |> select([o], {o.call_id, o.output})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Inside the commit that records the tool's result: takes a finished op's
  snapshot and closes the row, dropping the stored copy (hub rule 8).
  Returns nil if the row isn't finished.
  """
  @spec claim_tx(Tx.t(), String.t()) :: Operation.t() | nil
  def claim_tx(tx, op_id) do
    row = Repo.get(Op, op_id)
    {write, snapshot} = Rules.on_claim(row)
    :ok = apply_write(tx, row, write)
    snapshot
  end

  @doc """
  Inside the commit that ends the call another way (Stop, a failed task, an
  error result): sets `cancel` on an open row and sends `op.cancel` if the
  machine's channel is registered now; closes a finished row and drops its
  result (hub rule 7). Nothing for a closed row or none.
  """
  @spec cancel_tx(Tx.t(), String.t()) :: :ok
  def cancel_tx(tx, op_id) do
    row = Repo.get(Op, op_id)
    {write, pushes} = Rules.on_cancel(row, row_online?(row))
    :ok = apply_write(tx, row, write)
    send_all(row, pushes)
  end

  @doc """
  Inside the commit that gives up on an offline machine (hub rule 7): an op
  that finished meanwhile is claimed as `claim_tx/2` does it, and the call
  returns its real result. Otherwise the row is canceled as `cancel_tx/2`
  does it, and the facts (`pushed`, `confirmed`, and whether the machine is
  connected now) say what the offline message may claim.
  """
  @spec abandon_tx(Tx.t(), String.t()) :: abandoned()
  def abandon_tx(tx, op_id) do
    row = Repo.get(Op, op_id)

    case Rules.on_abandon(row, row_online?(row)) do
      {:claimed, snapshot, write} ->
        :ok = apply_write(tx, row, write)
        {:claimed, snapshot}

      {:abandoned, facts, write, pushes} ->
        :ok = apply_write(tx, row, write)
        :ok = send_all(row, pushes)
        {:abandoned, facts}
    end
  end

  defp row_online?(%Op{machine: machine}), do: online?(machine)
  defp row_online?(nil), do: false

  # Sends from inside a commit; see the moduledoc.
  defp send_all(_row, []), do: :ok

  defp send_all(%Op{machine: machine}, pushes) do
    Enum.each(pushes, fn {event, payload} ->
      # Offline is fine: a machine that dropped since `row_online?/1` gets its
      # `op.cancel` from its next join, since the row keeps `cancel`.
      _ = command(machine, event, payload)
    end)
  end

  ## A machine's channel

  @doc """
  What to send a machine that has just joined: `op.start` for each of its
  open rows without `cancel`, and `op.cancel` for each canceled one (hub
  rules 2 and 7). The rows it starts are marked `pushed` in the same commit.

  An `:outdated` machine (connected without `ops:2`) gets nothing and no
  row is written: its rows stay open, so the same node reinstalled with a
  current build gets them on its next join, and the calls waiting on them
  end with the outdated message at their next check
  (`Photon.MachineTools.Call`).
  """
  @spec joined(String.t()) :: [Wire.push()]
  def joined(machine) do
    if status(machine) == :outdated, do: [], else: Durable.commit(&joined_tx(&1, machine))
  end

  defp joined_tx(tx, machine) do
    rows =
      Op
      |> where([o], o.machine == ^machine and o.status == "open")
      |> order_by([o], asc: o.inserted_at, asc: o.id)
      |> Repo.all()

    {writes, pushes} = Rules.on_join(rows)
    by_id = Map.new(rows, &{&1.id, &1})

    Enum.each(writes, fn {id, changes} ->
      :ok = apply_write(tx, Map.fetch!(by_id, id), changes)
    end)

    pushes
  end

  @doc """
  The `op.start` for op `op_id` on `machine`, built from its row as it is
  now, or nothing if the row isn't open, is canceled, or isn't the
  machine's (hub rule 2), or the machine is `:outdated` (see `joined/1`).
  The channel calls it when asked to push an op.
  """
  @spec push_for(String.t(), String.t()) :: [Wire.push()]
  def push_for(machine, op_id) do
    if status(machine) == :outdated,
      do: [],
      else: Durable.commit(&push_for_tx(&1, machine, op_id))
  end

  defp push_for_tx(tx, machine, op_id) do
    row =
      case Repo.get(Op, op_id) do
        %Op{machine: ^machine} = row -> row
        _missing_or_foreign -> nil
      end

    {write, pushes} = Rules.push_for(row)
    :ok = apply_write(tx, row, write)
    pushes
  end

  @doc """
  Takes an `op.snapshot` payload from `machine` (hub rules 3 to 6) and
  returns what to send back, once the snapshot is recorded: `op.ack` for a
  result the hub holds, `op.cancel` for an op that shouldn't run. A result
  is stored and its signal fired in one commit. A snapshot for another
  machine's op is logged and ignored.

  A terminal snapshot also drops the op from the channel's `routes`.
  """
  @spec snapshot(String.t(), map(), routes()) :: {[Wire.push()], routes()}
  def snapshot(machine, payload, routes) do
    case Wire.parse_snapshot(payload) do
      {:ok, %{"id" => id} = snapshot} ->
        pushes = Durable.commit(&snapshot_tx(&1, machine, snapshot))
        {pushes, if(Operation.terminal?(snapshot), do: Map.delete(routes, id), else: routes)}

      {:error, reason} ->
        Logger.warning("#{machine} sent a snapshot the hub can't read: #{reason}")
        {[], routes}
    end
  end

  defp snapshot_tx(tx, machine, %{"id" => id} = snapshot) do
    row = Repo.get(Op, id)

    case Rules.on_snapshot(row, machine, snapshot) do
      :foreign ->
        Logger.warning("#{machine} sent a snapshot for #{id}, which runs on #{row.machine}")
        []

      {write, pushes} ->
        :ok = apply_write(tx, row, write)
        pushes
    end
  end

  @doc """
  Takes an `op.output` payload from `machine` and broadcasts the text to the
  tool call's conversation as a `"tool_output"` live event. Nothing is
  stored. Output for an op that isn't open on this machine is dropped.
  Returns `routes` with the op's route cached.
  """
  @spec output(String.t(), map(), routes()) :: routes()
  def output(machine, payload, routes) do
    case Wire.parse_output(payload) do
      {:ok, %{"id" => id} = output} ->
        case route(routes, machine, id) do
          {conversation_id, call_id} = route ->
            :ok = live(conversation_id, call_id, output)
            Map.put(routes, id, route)

          nil ->
            routes
        end

      {:error, reason} ->
        Logger.debug("#{machine} sent output the hub can't read: #{reason}")
        routes
    end
  end

  defp route(routes, machine, id) do
    case Map.fetch(routes, id) do
      {:ok, route} -> route
      :error -> read_route(machine, id)
    end
  end

  defp read_route(machine, id) do
    case Repo.get(Op, id) do
      %Op{machine: ^machine, status: "open"} = row -> {row.conversation_id, row.call_id}
      _closed_missing_or_foreign -> nil
    end
  end

  defp live(nil, _call_id, _output), do: :ok

  defp live(conversation_id, call_id, %{"stream" => stream, "text" => text}) do
    Durable.live(conversation_id, %{
      "type" => "tool_output",
      "call_id" => call_id,
      "stream" => stream,
      "text" => text
    })
  end

  ## Applying writes

  # Applies a `Rules` write to `row` inside the commit `tx`; a finished op
  # fires its signal in the same commit (hub rule 4).
  defp apply_write(_tx, _row, :none), do: :ok

  defp apply_write(tx, %Op{} = row, {:finish, changes}) do
    :ok = apply_write(tx, row, changes)
    Tx.signal(tx, signal_key(row.id), %{"status" => changes.status})
  end

  defp apply_write(_tx, %Op{} = row, changes) when is_map(changes) do
    _row = Repo.update!(Ecto.Changeset.change(row, changes))
    :ok
  end
end
