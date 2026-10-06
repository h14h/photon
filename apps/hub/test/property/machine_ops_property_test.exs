defmodule Photon.Property.MachineOpsTest do
  @moduledoc """
  Op rows under any mix of node reports and tool actions: snapshots
  delivered more than once, stale non-terminal ones after the result,
  snapshots from the wrong machine and for unknown ops, reconnects that
  resend everything, cancels and claims. Against `Photon.Machines` with the
  real database, after every step:

    * a row only moves forward (open, then finished, then closed), so an op
      is finished at most once
    * its signal has fired exactly when the row is no longer open
    * `op.ack` goes out only for ops whose row is finished or closed (or
      that have no row)
    * no `op.start` goes out for a canceled row
    * a result is claimed at most once
  """

  use Photon.DataCase, async: false
  use ExUnitProperties

  import Photon.MachineOps

  alias Photon.{Durable, Machines, Repo}
  alias Photon.Machines.Op

  @moduletag :durable
  @machine "mm1"
  @unknown "op_unknown"

  defp runs(default), do: String.to_integer(System.get_env("PHOTON_PROPERTY_RUNS", "#{default}"))

  @statuses ~w(ready awaiting canceling completed failed canceled)

  defp step(ops) do
    op = member_of(ops)

    frequency([
      {6,
       gen all(
             id <- one_of([op, constant(@unknown)]),
             status <- member_of(@statuses),
             machine <- frequency([{5, constant(@machine)}, {1, constant("mm2")}])
           ) do
         {:snapshot, id, status, machine}
       end},
      {2, constant(:reconnect)},
      {2, map(op, &{:push, &1})},
      {2, map(op, &{:cancel, &1})},
      {2, map(op, &{:claim, &1})},
      {1, map(op, &{:abandon, &1})}
    ])
  end

  property "op rows record each result once, and pushes follow the rows" do
    tasks = for _ <- 1..3, do: live_task()
    ops = Enum.map(tasks, &op_id(&1.id))

    check all(steps <- list_of(step(ops), max_length: 25), max_runs: runs(40)) do
      reset(tasks)

      Enum.reduce(steps, %{statuses: Map.new(ops, &{&1, "open"}), sent: %{}, claims: %{}}, fn
        step, model ->
          model = run(step, model)
          check_rows(ops, model)
      end)
    end
  end

  # Fresh rows (and no signals) for each run; the tasks stay live.
  defp reset(tasks) do
    Repo.query!("DELETE FROM machine_ops")
    Repo.query!("DELETE FROM signals")
    for task <- tasks, do: :ok = Machines.start(new_op(task, @machine))
  end

  defp run({:snapshot, id, status, machine}, model) do
    {pushes, _routes} = Machines.snapshot(machine, snapshot(id, status), %{})
    check_acks(pushes)
    sent = if machine == @machine, do: Map.put(model.sent, id, status), else: model.sent
    %{model | sent: sent}
  end

  # The node rejoins: the hub pushes what it holds, and the node resends
  # the latest snapshot of everything it has reported.
  defp run(:reconnect, model) do
    check_starts(Machines.joined(@machine))

    for {id, status} <- model.sent do
      {pushes, _routes} = Machines.snapshot(@machine, snapshot(id, status), %{})
      check_acks(pushes)
    end

    model
  end

  defp run({:push, id}, model) do
    check_starts(Machines.push_for(@machine, id))
    model
  end

  defp run({:cancel, id}, model) do
    :ok = Durable.commit(&Machines.cancel_tx(&1, id))
    model
  end

  defp run({:claim, id}, model) do
    case Durable.commit(&Machines.claim_tx(&1, id)) do
      nil -> model
      %{} -> claimed(model, id)
    end
  end

  defp run({:abandon, id}, model) do
    case Durable.commit(&Machines.abandon_tx(&1, id)) do
      {:claimed, _snapshot} -> claimed(model, id)
      {:abandoned, _facts} -> model
    end
  end

  defp claimed(model, id) do
    refute Map.has_key?(model.claims, id), "#{id}'s result was claimed twice"
    %{model | claims: Map.put(model.claims, id, true)}
  end

  defp check_acks(pushes) do
    for {"op.ack", %{"id" => id}} <- pushes do
      row = Repo.get(Op, id)
      assert row == nil or row.status != "open", "op.ack for #{id}, whose row is still open"
    end
  end

  defp check_starts(pushes) do
    for {"op.start", %{"id" => id}} <- pushes do
      row = Repo.get(Op, id)
      assert %Op{status: "open", cancel: false} = row, "op.start for #{id}: #{inspect(row)}"
    end
  end

  @forward %{"open" => ~w(open finished closed), "finished" => ~w(finished closed)}

  defp check_rows(ops, model) do
    statuses =
      Map.new(ops, fn id ->
        %Op{status: status} = Repo.get(Op, id)
        fired? = Durable.signal_payload(Machines.signal_key(id)) != nil

        assert status in Map.get(@forward, model.statuses[id], ["closed"]),
               "#{id} went from #{model.statuses[id]} to #{status}"

        assert fired? == (status != "open"), "#{id} is #{status}, signal fired: #{fired?}"
        {id, status}
      end)

    assert Repo.get(Op, @unknown) == nil
    %{model | statuses: statuses}
  end
end
