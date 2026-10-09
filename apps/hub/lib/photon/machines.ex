defmodule Photon.Machines do
  @moduledoc """
  Machines and the operations the hub runs on them. `docs/operations.md`
  has the protocol's guarantees and rules.

  A machine is online exactly as long as its node's connection lives. Each
  connection is a `PhotonWeb.NodeChannel` process registered in
  `Photon.MachineRegistry` under the machine's ID (`register/2`), with the
  node's info as the value. Nothing here holds on to a pid; callers name
  machines by ID. The machines the hub knows but can't reach are the IDs
  of node keys that aren't revoked (`Photon.NodeKeys`), plus `local` when
  the hub runs its own node (`Photon.Machines.Roster`).

  An operation is a row (`Photon.Machines.Op`), one per tool call, keyed by
  the op ID the call derives from its durable task. The parked tool call
  waits on the signal `signal_key/1`, which fires in the commit that
  records the op's result.

  Every write is one commit (`Photon.Durable.commit/1`) that reads the row,
  asks `Photon.Machines.Rules` what to do, and applies the answer. The
  channel's reads (`joined/1`, `push_for/2`) are commits too, so they wait
  for a commit in progress and record `pushed` on the rows they return an
  `op.start` for. Only the machine's channel puts an `op.start` on the
  wire, built from the row as it is when the channel pushes it.

  Commands to a channel are plain sends, not calls: the caller (a tool
  step, or a commit) must not wait on a node's connection. Ops are pushed
  again on every join and every minute while their call waits on an
  online machine, so a lost command costs a delay, not the op.

  The channel sends the pushes it gets back after the commit returns, so
  an `op.ack` never leaves before the result is stored. The exception is
  `op.cancel` from `cancel_tx/2` and `abandon_tx/2`, sent from inside the
  caller's commit: a node journals a cancel, so one sent by a commit that
  then rolls back is safe.

  Node payloads are parsed once, here, with `PhotonCore.Operation.Wire`;
  everything behind this module trusts them. A payload that doesn't parse
  is logged and dropped.

  Live output is never stored, except that a call that ended another way
  (stopped, say) keeps the tail its op's final snapshot carried
  (`stopped_outputs/1`): all there is to show of it after a reload.

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
  alias PhotonCore.Operation.{Result, Wire}

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
  The state of `machine`: `:outdated` is connected but an older
  photon-node. `local` is known whenever the hub runs its own node (hub
  rule 12).
  """
  @spec status(String.t()) :: Roster.status()
  def status(machine), do: Roster.status(machine, get(machine), known_ids(), local_node?())

  @doc "Every machine the hub knows, `local` first, then connected ones, then offline ones."
  @spec roster() :: [Roster.machine()]
  def roster, do: Roster.build(list(), known_ids(), local_node?())

  @doc """
  The IDs of every machine the hub knows, connected or offline but not
  removed, in an order that ignores who is connected
  (`Photon.Machines.Roster.ids/3`).
  """
  @spec known() :: [String.t()]
  def known, do: Roster.ids(list(), known_ids(), local_node?())

  defp known_ids, do: for(%{node_id: id, revoked_at: nil} <- NodeKeys.list(), do: id)

  defp local_node?, do: Application.get_env(:photon, :local_node, false) == true

  ## Operations, for tool calls

  @doc """
  Records an op and asks its machine's channel to push it (hub rules 1, 2
  and 9); an offline machine gets it when it joins. The row is inserted
  only while the tool task is unfinished and not marked for abort, and
  only once: a rerun finds the row and asks for the same op again.
  `{:error, :stopped}`, with nothing inserted or pushed, when the task has
  ended or is being aborted.
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
  pushes `op.start` if the row is still open and not canceled.
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
  call ID, as the rows kept it (`Photon.Machines.Rules.output/1`).
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
  Inside the commit that ends the call another way (Stop, a failed task,
  an error result): `Photon.Machines.Rules.on_cancel/2` (hub rule 7),
  sending `op.cancel` if the machine's channel is registered now.
  """
  @spec cancel_tx(Tx.t(), String.t()) :: :ok
  def cancel_tx(tx, op_id) do
    row = Repo.get(Op, op_id)
    {write, pushes} = Rules.on_cancel(row, row_online?(row))
    :ok = apply_write(tx, row, write)
    send_all(row, pushes)
  end

  @doc """
  Inside the commit that gives up on an offline machine:
  `Photon.Machines.Rules.on_abandon/2` (hub rule 7). An op that finished
  meanwhile is claimed, and the call returns its real result.
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
  What to send a machine that has just joined
  (`Photon.Machines.Rules.on_join/1`, hub rules 2 and 7), with the rows it
  starts marked `pushed` in the same commit.

  An `:outdated` machine gets nothing and no row is written: its rows stay
  open for the same node reinstalled with a current build, and the calls
  waiting on them end at their next check (`Photon.MachineTools.Call`).
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
  Takes an `op.snapshot` payload from `machine` and returns what to send
  back once the snapshot is recorded (`Photon.Machines.Rules.on_snapshot/3`,
  hub rules 3 to 6). A result is stored and its signal fired in one
  commit. A terminal snapshot also drops the op from the channel's
  `routes`.
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

  # A result the tool call couldn't read becomes a failure it reports. It
  # is read as the kind of op the hub asked for, whatever the node says.
  defp readable(_machine, snapshot, nil = _row), do: snapshot

  defp readable(machine, snapshot, %Op{kind: kind}) do
    case Result.accept(snapshot, kind) do
      {:ok, snapshot} ->
        snapshot

      {:malformed, failed, reason} ->
        Logger.warning("#{machine} sent a malformed result for #{snapshot["id"]}: #{reason}")
        failed
    end
  end

  defp snapshot_tx(tx, machine, %{"id" => id} = snapshot) do
    row = Repo.get(Op, id)
    snapshot = readable(machine, snapshot, row)

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
  Takes an `op.output` payload from `machine` and broadcasts the text to
  the tool call's conversation as a `"tool_output"` live event, unstored.
  Output for an op that isn't open on this machine is dropped. Returns
  `routes` with the op's route cached.
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
