defmodule PhotonNode.Executor do
  @moduledoc """
  Runs the hub's operations on this node (`docs/operations.md`, node rules 1
  to 9): one process for all of them, owning their journal
  (`PhotonNode.Executor.Journal`) and their processes
  (`PhotonNode.Ops.Owner`). Every journal write goes through it, so a
  cancel flag and a snapshot never overwrite each other.

  Each snapshot an operation reports is fitted to the frame budget
  (`Request.fit/2`), journaled, then forwarded through
  `PhotonNode.Executor.Link`. A shell command's `process` checkpoint is
  answered only once it is journaled, and `:cancel` if the journal says
  canceled (node rule 4). Live output goes from the operation process
  straight to the link. The decisions are pure
  (`PhotonNode.Executor.Request`, `PhotonNode.Executor.Rules`); this module
  reads the journal and the registry, calls them, and does what they say
  (rule 71).

  A failed journal write never runs anything (node rule 8). A result that
  couldn't be journaled is forwarded anyway and held in memory
  (`unjournaled`) until its `op.ack`. Every decision reads it in place of
  the journal's older entry, and a `ready` entry under it is removed
  (`Rules.on_unjournaled/1`), so nothing starts the operation again.

  `checkpoint/2` and `report/2` wait with no timeout (a journal scan, or
  the fsync of a large image snapshot) and return at once if this process
  dies. The wait can't deadlock: this process never calls an operation
  process synchronously (`Ops.add/2` starts a child whose `init/1` returns
  at once, or sends `:resend`).

  On start it scans the journal and resends or resumes every unfinished
  operation (`Rules.on_scan/2`). It monitors every operation process (rule
  87) and applies `Rules.down/3` to each exit. A crash of this process
  loses only its monitors and restart counts, which the scan rebuilds.
  Once a day (and at start-up) it sweeps the output of operations
  acknowledged more than 7 days ago.
  """

  # `Link` is the contract the hub link implements.
  use Boundary,
    deps: [PhotonNode, PhotonNode.Config, PhotonNode.Ops, PhotonCore, Jason],
    exports: [Link]

  use GenServer

  @behaviour PhotonNode.Ops.Owner

  require Logger

  alias PhotonCore.Operation
  alias PhotonNode.Config
  alias PhotonNode.Executor.{Journal, Link, Request, Rules}
  alias PhotonNode.Ops
  alias PhotonNode.Ops.{Env, Owner}

  # One executor, so its owner ID only says whose operations they are.
  @owner {__MODULE__, :hub}

  @max_age 7 * 24 * 60 * 60
  @sweep_ms 24 * 60 * 60 * 1000

  @enforce_keys [:facts]
  defstruct [:facts, monitors: %{}, restarted: MapSet.new(), unjournaled: %{}]

  @typedoc """
  The process state: the node's facts for `Request`, the monitors of
  operation processes, the operations restarted once after a clean exit,
  and the results forwarded without being journaled, until their `op.ack`.
  """
  @type t :: %__MODULE__{
          facts: Request.facts(),
          monitors: %{reference() => {String.t(), pid()}},
          restarted: MapSet.t(String.t()),
          unjournaled: %{String.t() => Operation.t()}
        }

  ## API

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Handles a parsed `op.start` (`PhotonCore.Operation.Wire.parse_start/1`)
  as `Rules.on_start/3` decides, or answers it with a `failed` snapshot (an
  unsupported kind, bad arguments, a failed journal write). Returns once
  that is done; exits if the executor dies first.
  """
  @spec start(Request.start()) :: :ok
  def start(start), do: GenServer.call(__MODULE__, {:start, start}, :infinity)

  @doc """
  Handles `op.cancel` (node rule 7): journals the cancel and tells the
  operation process. One the node has never seen is journaled as canceled
  and that snapshot sent, so a later `op.start` runs nothing. A finished
  operation is left alone.
  """
  @spec cancel(String.t()) :: :ok
  def cancel(id), do: GenServer.call(__MODULE__, {:cancel, id}, :infinity)

  @doc """
  Handles `op.ack`: forgets a finished operation's entry, keeping its
  output files for the sweep. An unknown or unfinished operation is ignored.
  """
  @spec ack(String.t()) :: :ok
  def ack(id), do: GenServer.call(__MODULE__, {:ack, id}, :infinity)

  @doc "Every journaled snapshot, in ID order: what the hub link sends after each join."
  @spec snapshots() :: [Operation.t()]
  def snapshots, do: GenServer.call(__MODULE__, :snapshots, :infinity)

  ## Ops.Owner

  @doc """
  Journals an operation's checkpoint before it acts on it. `:cancel` if
  its entry says canceled, `:ignored` if it has no unfinished entry or the
  executor didn't answer (any exit), `{:error, reason}` if the write failed.
  """
  @impl Owner
  @spec checkpoint(term(), Operation.t()) :: :ok | :cancel | :ignored | {:error, String.t()}
  def checkpoint(_owner_id, op) do
    GenServer.call(__MODULE__, {:checkpoint, op}, :infinity)
  catch
    :exit, _ -> :ignored
  end

  @doc """
  Journals an operation's snapshot and forwards it. `:down` if the
  executor didn't take it (any exit); the operation resends it when the
  restarted executor asks.
  """
  @impl Owner
  @spec report(term(), Operation.t()) :: :ok | :down
  def report(_owner_id, op) do
    GenServer.call(__MODULE__, {:report, op}, :infinity)
  catch
    :exit, _ -> :down
  end

  @doc "Streams an operation's new output to the hub link, from the operation's own process."
  @impl Owner
  @spec output(term(), String.t(), String.t(), String.t()) :: :ok
  def output(_owner_id, op_id, stream, text), do: Link.output(op_id, stream, text)

  ## Server

  @impl true
  def init(nil) do
    config = PhotonNode.config()
    facts = %{shell: Env.shell(), ops_dir: Config.ops_dir(config), workspace: config.workspace}
    {:ok, %__MODULE__{facts: facts}, {:continue, :scan}}
  end

  @impl true
  def handle_continue(:scan, state) do
    state = Enum.reduce(Journal.list(state.facts.ops_dir), state, &scan/2)
    {:noreply, sweep(state)}
  end

  @impl true
  def handle_call({:start, start}, _from, state), do: {:reply, :ok, start_op(state, start)}
  def handle_call({:cancel, id}, _from, state), do: {:reply, :ok, cancel_op(state, id)}
  def handle_call({:ack, id}, _from, state), do: {:reply, :ok, ack_op(state, id)}
  def handle_call(:snapshots, _from, state), do: {:reply, journaled(state), state}
  def handle_call({:checkpoint, op}, _from, state), do: {:reply, checkpoint_op(state, op), state}
  def handle_call({:report, op}, _from, state), do: {:reply, :ok, report_op(state, op)}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state),
    do: {:noreply, down(state, ref, reason)}

  def handle_info(:sweep, state), do: {:noreply, sweep(state)}
  def handle_info(_message, state), do: {:noreply, state}

  ## op.start

  defp start_op(state, %{"id" => id, "known" => known} = start) do
    case read(state, id) do
      {:ok, entry} ->
        on_start(state, start, entry, Rules.on_start(entry, known, Ops.running?(id)))

      {:error, reason} ->
        start_unreadable(state, start, reason)
    end
  end

  defp on_start(state, start, _entry, :run), do: run(state, start)

  defp on_start(state, start, _entry, :lost),
    do: answer(state, Request.lost(start["id"], start["kind"]))

  defp on_start(state, _start, entry, {:resend, cancel?}) do
    :ok = Link.snapshot(entry["op"])
    if cancel?, do: Ops.cancel(entry["op"]["id"])
    state
  end

  defp on_start(state, _start, entry, {:resume, cancel?}) do
    :ok = Link.snapshot(entry["op"])
    revive(state, entry, cancel?)
  end

  defp run(state, start) do
    case Request.operation(start, state.facts) do
      {:ok, op} -> run_journaled(state, op)
      {:error, reason} -> answer(state, Request.rejected(start, reason))
    end
  end

  # Node rules 1 and 8: nothing runs before its `ready` entry is on disk.
  defp run_journaled(state, op) do
    case journal(state, op, false) do
      {:ok, op} ->
        :ok = Link.snapshot(op)
        revive(state, entry(op, false), false)

      {{:error, reason}, _op} ->
        unrecorded = Request.unrecorded(op, reason)
        state |> hold(unrecorded) |> answer(unrecorded)
    end
  end

  # An entry that exists but can't be read: an operation still running
  # replaces it with its next snapshot; otherwise the node can't tell what
  # happened, and says so rather than run it again.
  defp start_unreadable(state, %{"id" => id} = start, reason) do
    Logger.error("operation #{id}'s journal entry can't be read: #{reason}")
    if Ops.running?(id), do: state, else: answer(state, Request.unreadable(start, reason))
  end

  ## op.cancel

  defp cancel_op(state, id) do
    case read(state, id) do
      {:ok, nil} ->
        cancel_unstarted(state, id)

      {:ok, %{"op" => op} = entry} ->
        if Operation.terminal?(op), do: state, else: cancel_unfinished(state, entry)

      {:error, reason} ->
        log_unjournaled(state, id, "its cancel is only sent to the process", reason)
        :ok = Ops.cancel(id)
        state
    end
  end

  # Node rule 7: journaled, so an `op.start` that comes later gets this
  # snapshot back and runs nothing. Unjournaled, it isn't answered: the hub
  # sends the cancel again on its next join.
  defp cancel_unstarted(state, id) do
    case journal(state, Request.never_started(id), true) do
      {:ok, op} -> answer(state, op)
      {{:error, reason}, _op} -> log_unjournaled(state, id, "its cancel isn't answered", reason)
    end
  end

  defp cancel_unfinished(state, %{"op" => %{"id" => id}} = entry) do
    entry = %{entry | "cancel" => true}

    with {:error, reason} <- Journal.write(ops_dir(state), id, entry),
         do: log_unjournaled(state, id, "it is canceled without a record", reason)

    case Rules.on_scan(entry, Ops.running?(id)) do
      {:resume, cancel?} ->
        revive(state, entry, cancel?)

      {:resend, _cancel?} ->
        :ok = Ops.cancel(id)
        state
    end
  end

  ## op.ack

  # Node rule 6. An unreadable entry was answered with a failed snapshot
  # (unless a process runs it), and the hub has recorded that.
  defp ack_op(state, id) do
    case read(state, id) do
      {:ok, nil} -> state
      {:ok, %{"op" => op}} -> if Operation.terminal?(op), do: forget(state, id), else: state
      {:error, _reason} -> if Ops.running?(id), do: state, else: forget(state, id)
    end
  end

  defp forget(state, id) do
    with {:error, reason} <- Journal.forget(ops_dir(state), id),
         do: Logger.warning("couldn't forget operation #{id}: #{reason}")

    %{
      state
      | restarted: MapSet.delete(state.restarted, id),
        unjournaled: Map.delete(state.unjournaled, id)
    }
  end

  ## Owner callbacks

  # Node rule 4: the command spawns only once this is journaled, and only
  # if the journal doesn't say canceled.
  defp checkpoint_op(state, %{"id" => id} = op) do
    case read(state, id) do
      {:ok, %{"op" => journaled, "cancel" => cancel}} -> confirm(state, op, journaled, cancel)
      {:ok, nil} -> :ignored
      {:error, reason} -> {:error, reason}
    end
  end

  defp confirm(state, op, journaled, cancel) do
    cond do
      Operation.terminal?(journaled) -> :ignored
      cancel -> :cancel
      true -> confirm_journaled(journal(state, op, false))
    end
  end

  defp confirm_journaled({:ok, op}), do: Link.snapshot(op)
  defp confirm_journaled({{:error, reason}, _op}), do: {:error, reason}

  # A snapshot after a finished one (nothing should send one) changes
  # nothing, so the journal keeps the result.
  defp report_op(state, %{"id" => id} = op) do
    case read(state, id) do
      {:ok, %{"op" => journaled, "cancel" => cancel}} ->
        if Operation.terminal?(journaled), do: state, else: record(state, op, cancel)

      {:ok, nil} ->
        Logger.warning("ignoring a snapshot of operation #{id}, which has no journal entry")
        state

      {:error, reason} ->
        log_unjournaled(state, id, "its snapshot is forwarded anyway", reason)
        state |> hold(op) |> answer(op)
    end
  end

  ## Operation processes

  # `Ops.add/2` starts the operation or has its process resend; then it is
  # monitored, and told to cancel when `cancel?` (node rule 2).
  defp revive(state, %{"op" => op} = entry, cancel?) do
    case Ops.add(op, @owner) do
      {:ok, pid} ->
        if cancel?, do: Ops.cancel(op["id"])
        watch(state, op["id"], pid)

      {:error, reason} ->
        message = "photon-node couldn't start the operation: #{reason_text(reason)}"
        record(state, Request.failed(op, message), entry["cancel"])
    end
  end

  defp scan(entry, state) do
    case Rules.on_scan(entry, Ops.running?(entry["op"]["id"])) do
      :skip -> state
      {_resend_or_resume, cancel?} -> revive(state, entry, cancel?)
    end
  end

  defp watch(state, id, pid) do
    if Enum.any?(state.monitors, fn {_ref, watched} -> watched == {id, pid} end),
      do: state,
      else: %{state | monitors: Map.put(state.monitors, Process.monitor(pid), {id, pid})}
  end

  # An exit of a process that has been replaced (its operation is
  # monitored again under a newer process) means nothing.
  defp down(state, ref, reason) do
    case Map.pop(state.monitors, ref) do
      {{id, _pid}, monitors} ->
        state = %{state | monitors: monitors}
        if watched?(state, id), do: state, else: exited(state, id, reason)

      {nil, _monitors} ->
        state
    end
  end

  defp watched?(state, id), do: Enum.any?(state.monitors, &match?({_ref, {^id, _pid}}, &1))

  defp exited(state, id, reason) do
    entry = readable_entry(state, id)

    case Rules.down(entry, reason, MapSet.member?(state.restarted, id)) do
      :ignore ->
        state

      {:restart, cancel?} ->
        revive(%{state | restarted: MapSet.put(state.restarted, id)}, entry, cancel?)

      {:fail, message} ->
        record(state, Request.failed(entry["op"], message), entry["cancel"])
    end
  end

  defp readable_entry(state, id) do
    case read(state, id) do
      {:ok, entry} ->
        entry

      {:error, reason} ->
        Logger.error("operation #{id} exited and its journal entry can't be read: #{reason}")
        nil
    end
  end

  ## Journal

  # The operation's entry as the executor knows it: a result it forwarded
  # without journaling stands in for whatever the journal still holds.
  defp read(state, id) do
    case Map.fetch(state.unjournaled, id) do
      {:ok, op} -> {:ok, entry(op, false)}
      :error -> Journal.read(ops_dir(state), id)
    end
  end

  # Every snapshot the hub should have, the held results in place of what
  # the journal holds for them.
  defp journaled(state) do
    state
    |> ops_dir()
    |> Journal.list()
    |> Map.new(&{&1["op"]["id"], &1["op"]})
    |> Map.merge(state.unjournaled)
    |> Enum.sort_by(fn {id, _op} -> id end)
    |> Enum.map(fn {_id, op} -> op end)
  end

  # Node rule 9: fitted to the frame budget, then journaled.
  defp journal(state, op, cancel) do
    op = Request.fit(op, Request.snapshot_budget())
    {Journal.write(ops_dir(state), op["id"], entry(op, cancel)), op}
  end

  # Node rules 5 and 8: journaled, then forwarded; a snapshot that can't be
  # journaled is forwarded anyway, and the journal keeps the older one.
  defp record(state, op, cancel) do
    case journal(state, op, cancel) do
      {:ok, op} ->
        answer(state, op)

      {{:error, reason}, op} ->
        log_unjournaled(state, op["id"], "its snapshot is forwarded anyway", reason)
        state |> hold(op) |> answer(op)
    end
  end

  # Node rule 8: see the moduledoc and `read/2`.
  defp hold(state, %{"id" => id} = op) do
    if Operation.terminal?(op) do
      :ok = remove_runnable(state, id)
      %{state | unjournaled: Map.put(state.unjournaled, id, op)}
    else
      state
    end
  end

  defp remove_runnable(state, id) do
    with {:ok, entry} <- Journal.read(ops_dir(state), id),
         :remove <- Rules.on_unjournaled(entry),
         {:error, reason} <- Journal.discard(ops_dir(state), id) do
      Logger.error(
        "couldn't remove operation #{id}'s ready entry, so a restart may run it: #{reason}"
      )
    else
      _removed_kept_or_unreadable -> :ok
    end
  end

  defp entry(op, cancel), do: %{"op" => op, "cancel" => cancel}

  defp answer(state, op) do
    :ok = Link.snapshot(op)
    state
  end

  defp log_unjournaled(state, id, consequence, reason) do
    Logger.error("couldn't journal operation #{id}, so #{consequence}: #{reason}")
    state
  end

  defp sweep(state) do
    removed = Journal.sweep(ops_dir(state), System.os_time(:second), @max_age)

    if removed != [],
      do: Logger.info("swept the output of #{length(removed)} acknowledged operations")

    Process.send_after(self(), :sweep, @sweep_ms)
    state
  end

  defp ops_dir(state), do: state.facts.ops_dir

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)
end
