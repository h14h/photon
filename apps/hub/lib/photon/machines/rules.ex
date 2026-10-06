defmodule Photon.Machines.Rules do
  @moduledoc """
  The hub's rules for operation rows (section 2.3 of
  `docs/plans/step-1-machine-tools.md`), as pure functions.
  `Photon.Machines` reads a row inside a Store commit, calls one of these,
  and applies what it returns in the same commit.

  A write is what to do to the row:

    * `:none`: nothing
    * a map of field changes, such as `%{confirmed: true}`
    * `{:finish, changes}`: the changes that record a terminal snapshot;
      the same commit fires the signal `"op:" <> id` (rule 4)

  A push is `{event, payload}` from `PhotonCore.Operation.Wire`, for the
  machine's channel to send.

  The rules, by number:

    * 2: `push_for/1` and `on_join/1` build `op.start` only for an open row
      without `cancel`, from the row as it is, and set `pushed`
    * 3 to 6: `on_snapshot/3` confirms, finishes, acks or cancels
    * 7: `on_join/1` resends `op.cancel` for canceled open rows;
      `on_cancel/2` and `on_abandon/2` set `cancel` on an open row and close
      a finished one
    * 8: `on_claim/1` closes a finished row and hands over its snapshot
    * 9: `insert?/2` lets `Machines.start/1` insert a row only for a live
      tool task
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [Photon.Machines.Op, PhotonCore]

  alias Photon.Machines.Op
  alias PhotonCore.Operation
  alias PhotonCore.Operation.Wire

  # Durable task statuses that are not yet terminal (`Photon.Durable.TaskRecord`).
  @unfinished_tasks ~w(pending running waiting)

  @typedoc "Field changes for a row."
  @type changes :: %{optional(atom()) => term()}

  @typedoc "What to do to a row; see the moduledoc."
  @type write :: :none | changes() | {:finish, changes()}

  @typedoc "What `on_abandon/2` learned, for the offline message."
  @type facts :: %{pushed: boolean(), confirmed: boolean(), online: boolean()}

  @doc """
  Whether `Machines.start/1` may insert a row for a tool task with this
  status (nil when there is no such task): only while it is unfinished and
  not marked for abort (rule 9).
  """
  @spec insert?(String.t() | nil, boolean()) :: boolean()
  def insert?(task_status, abort_requested?),
    do: task_status in @unfinished_tasks and not abort_requested?

  @doc """
  The `op.start` for a row, built from the row as it is, and the write that
  records `pushed`. Nothing for a row that isn't open, is canceled, or
  doesn't exist (rule 2).
  """
  @spec push_for(Op.t() | nil) :: {write(), [Wire.push()]}
  def push_for(%Op{status: "open", cancel: false} = row),
    do: {pushed(row), [Wire.start(row.id, row.kind, row.args, row.confirmed)]}

  def push_for(_row), do: {:none, []}

  @doc """
  What a channel sends when its machine joins, for that machine's rows:
  `op.start` for each open row without `cancel` (and `pushed` set on it),
  `op.cancel` for each open row with `cancel`, nothing for the rest (rules
  2 and 7). The writes name their rows by ID; rows that need none are left
  out.
  """
  @spec on_join([Op.t()]) :: {[{String.t(), changes()}], [Wire.push()]}
  def on_join(rows) do
    {writes, pushes} = Enum.reduce(rows, {[], []}, &join_row/2)
    {Enum.reverse(writes), pushes |> Enum.reverse() |> List.flatten()}
  end

  defp join_row(%Op{status: "open", cancel: true} = row, {writes, pushes}),
    do: {writes, [[Wire.cancel(row.id)] | pushes]}

  defp join_row(row, {writes, pushes}) do
    case push_for(row) do
      {:none, more} -> {writes, [more | pushes]}
      {changes, more} -> {[{row.id, changes} | writes], [more | pushes]}
    end
  end

  @doc """
  What a snapshot from `machine` does to its row (rules 3 to 6):

    * open row, non-terminal: set `confirmed`
    * open row, terminal: finish it (`finished` with the snapshot kept, or
      `closed` without it if the row was canceled), set `confirmed`, and
      `op.ack`
    * finished or closed row, or no row: `op.ack` for a terminal snapshot,
      `op.cancel` for any other
    * a row that belongs to another machine: `:foreign`, which changes
      nothing and is logged
  """
  @spec on_snapshot(Op.t() | nil, String.t(), Operation.t()) ::
          {write(), [Wire.push()]} | :foreign
  def on_snapshot(%Op{machine: owner}, machine, _snapshot) when owner != machine, do: :foreign

  def on_snapshot(%Op{status: "open"} = row, _machine, snapshot) do
    if Operation.terminal?(snapshot),
      do: {{:finish, finish(row, snapshot)}, [Wire.ack(row.id)]},
      else: {confirmed(row), []}
  end

  def on_snapshot(_row_or_nil, _machine, %{"id" => id} = snapshot),
    do: {:none, [if(Operation.terminal?(snapshot), do: Wire.ack(id), else: Wire.cancel(id))]}

  defp finish(%Op{cancel: true}, _snapshot),
    do: %{status: "closed", confirmed: true, result: nil}

  defp finish(%Op{}, snapshot), do: %{status: "finished", confirmed: true, result: snapshot}

  @doc """
  The tool claims a finished row's result: the row closes and its snapshot
  is dropped, so a large image isn't kept twice (rule 8). Any other row has
  nothing to claim.
  """
  @spec on_claim(Op.t() | nil) :: {write(), Operation.t() | nil}
  def on_claim(%Op{status: "finished", result: snapshot}), do: {closed(), snapshot}
  def on_claim(_row), do: {:none, nil}

  @doc """
  The call ended another way (user Stop, a failed task, an error result):
  an open row gets `cancel`, and `op.cancel` if the machine's channel is
  registered (`online?`); a finished row closes and drops the result
  nobody will claim (rule 7). Closed rows and missing ones change nothing.
  """
  @spec on_cancel(Op.t() | nil, boolean()) :: {write(), [Wire.push()]}
  def on_cancel(%Op{status: "open"} = row, online?),
    do: {canceled(row), cancel_push(row, online?)}

  def on_cancel(%Op{status: "finished"}, _online?), do: {closed(), []}
  def on_cancel(_row, _online?), do: {:none, []}

  @doc """
  The call gives up on an offline machine (rule 7). A row that finished
  meanwhile is claimed as `on_claim/1` does it, and the call returns the
  real result. Otherwise an open row gets `cancel` (and `op.cancel` if the
  machine's channel is registered now), and the facts say what the offline
  message may claim: `pushed`, `confirmed` and `online`.
  """
  @spec on_abandon(Op.t() | nil, boolean()) ::
          {:claimed, Operation.t(), write()} | {:abandoned, facts(), write(), [Wire.push()]}
  def on_abandon(%Op{status: "finished", result: snapshot}, _online?),
    do: {:claimed, snapshot, closed()}

  def on_abandon(row, online?) do
    {write, pushes} = on_cancel(row, online?)
    {:abandoned, facts(row, online?), write, pushes}
  end

  defp facts(%Op{} = row, online?),
    do: %{pushed: row.pushed, confirmed: row.confirmed, online: online?}

  defp facts(nil, online?), do: %{pushed: false, confirmed: false, online: online?}

  defp cancel_push(row, true), do: [Wire.cancel(row.id)]
  defp cancel_push(_row, false), do: []

  defp pushed(%Op{pushed: true}), do: :none
  defp pushed(%Op{}), do: %{pushed: true}

  defp confirmed(%Op{confirmed: true}), do: :none
  defp confirmed(%Op{}), do: %{confirmed: true}

  defp canceled(%Op{cancel: true}), do: :none
  defp canceled(%Op{}), do: %{cancel: true}

  defp closed, do: %{status: "closed", result: nil}
end
