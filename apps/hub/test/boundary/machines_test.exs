defmodule Photon.MachinesTest do
  @moduledoc """
  `Photon.Machines` through its API, against the real database and Store.
  A machine is "online" when the test process registers as its connection
  (`Photon.Machines.register/2`), so what the API sends a channel arrives in
  the test's mailbox. The rules themselves are covered in
  `test/core/machines/rules_test.exs`.
  """

  use Photon.DataCase, async: false

  import Photon.MachineOps

  alias Photon.{Durable, Machines, Repo}
  alias Photon.Durable.Tx
  alias Photon.Machines.Op

  @moduletag :durable

  defp row(id), do: Repo.get(Op, id)

  defp finish(machine, id),
    do:
      {[{"op.ack", %{"id" => ^id}}], _} =
        Machines.snapshot(machine, snapshot(id, "completed"), %{})

  describe "start/1" do
    test "commits the row and asks an online machine's channel to push it" do
      :ok = connect("mm1")
      {_task, %{id: id}} = started("mm1")

      assert_received {:push_op, ^id}

      assert %Op{machine: "mm1", kind: "shell", status: "open", pushed: false, cancel: false} =
               row(id)

      assert Machines.op_state(id) == {:open, false}
    end

    test "sends nothing to an offline machine; its join pushes the op and marks it pushed" do
      {_task, %{id: id}} = started("mm1")
      refute_received {:push_op, _}

      assert [{"op.start", %{"id" => ^id, "kind" => "shell", "known" => false}}] =
               Machines.joined("mm1")

      assert row(id).pushed
    end

    test "a rerun inserts nothing new and asks for the same op again" do
      :ok = connect("mm1")
      task = live_task()
      op = new_op(task, "mm1")
      :ok = Machines.start(op)
      :ok = Machines.start(%{op | args: %{"command" => "something else"}})

      id = op.id
      assert_received {:push_op, ^id}
      assert_received {:push_op, ^id}
      assert row(id).args["command"] == "echo hi"
    end

    test "inserts nothing for a task marked for abort, or finished" do
      :ok = connect("mm1")
      aborting = live_task()
      Durable.commit(&Tx.update_task(&1, aborting, abort_requested: true))
      done = live_task()
      Durable.commit(&Tx.update_task(&1, done, status: "done"))

      for task <- [aborting, done] do
        assert Machines.start(new_op(task, "mm1")) == {:error, :stopped}
        assert Machines.op_state(op_id(task.id)) == :none
      end

      assert Machines.start(%{new_op(live_task(), "mm1") | task_id: "t_gone"}) ==
               {:error, :stopped}

      refute_received {:push_op, _}
    end
  end

  describe "push_for/2 (hub rule 2)" do
    test "builds op.start from the row as it is, and marks it pushed" do
      {_task, %{id: id}} = started("mm1")
      refute row(id).pushed

      assert [{"op.start", %{"id" => ^id, "known" => false, "args" => %{"command" => "echo hi"}}}] =
               Machines.push_for("mm1", id)

      assert row(id).pushed

      {[], _routes} = Machines.snapshot("mm1", snapshot(id, "awaiting"), %{})
      assert [{"op.start", %{"known" => true}}] = Machines.push_for("mm1", id)
    end

    test "nothing once the row has finished: the stale-start trace" do
      {_task, %{id: id}} = started("mm1")
      finish("mm1", id)

      assert Machines.push_for("mm1", id) == []
      Durable.commit(&Machines.claim_tx(&1, id))
      assert Machines.push_for("mm1", id) == []
    end

    test "nothing for a canceled row, another machine's row, or an unknown op" do
      {_task, %{id: id}} = started("mm1")
      assert Machines.push_for("mm2", id) == []
      refute row(id).pushed

      :ok = Durable.commit(&Machines.cancel_tx(&1, id))
      assert Machines.push_for("mm1", id) == []
      assert Machines.push_for("mm1", "op_nothing") == []
    end
  end

  # Step 2, section 3.4 point 7: a step 1 node (ops:1) wouldn't create a
  # project's working directory, so it gets no ops until it is reinstalled.
  describe "an outdated machine" do
    test "joined/1 and push_for/2 push nothing and leave its open rows unpushed" do
      {_task, %{id: id}} = started("mm1")
      :ok = connect("mm1", ["ops:1"])

      assert Machines.joined("mm1") == []
      assert Machines.push_for("mm1", id) == []
      assert %Op{status: "open", pushed: false} = row(id)
    end
  end

  test "repush/1 asks the machine's channel to push the op again" do
    {_task, %{id: id}} = started("mm1")
    assert Machines.repush(id) == {:error, :offline}

    :ok = connect("mm1")
    assert Machines.repush(id) == :ok
    assert_received {:push_op, ^id}
    assert Machines.repush("op_nothing") == {:error, :not_found}
  end

  describe "status/1 and roster/0" do
    test "names connected, outdated, known offline and unknown machines" do
      {:ok, _key} = Photon.NodeKeys.issue("away")
      {:ok, _key} = Photon.NodeKeys.issue("gone")
      :ok = Photon.NodeKeys.revoke("gone")
      :ok = connect("mm1")

      assert Machines.status("mm1") == :online
      assert Machines.status("away") == :offline
      assert Machines.status("gone") == :unknown
      assert Machines.status("nowhere") == :unknown
      assert Machines.status("local") == :unknown

      assert [%{id: "mm1", online: true}, %{id: "away", online: false}] = Machines.roster()
    end

    test "a connected node without the ops capability is outdated" do
      :ok = connect("old", [])
      assert Machines.status("old") == :outdated
    end

    test "local is known, and offline, on a hub that runs its own node" do
      Application.put_env(:photon, :local_node, true)
      on_exit(fn -> Application.put_env(:photon, :local_node, false) end)

      assert Machines.status("local") == :offline
      assert [%{id: "local", online: false}] = Machines.roster()
    end
  end

  describe "snapshot/3 (hub rules 3 to 6)" do
    test "a result is stored with its signal, then acked" do
      {_task, %{id: id}} = started("mm1")
      key = Machines.signal_key(id)

      assert {[], _routes} = Machines.snapshot("mm1", snapshot(id, "awaiting"), %{})
      assert Machines.op_state(id) == {:open, true}
      assert Durable.signal_payload(key) == nil

      routes = %{id => {"c_x", "call_x"}}
      result = snapshot(id, "completed", %{"result" => %{"out" => "hi"}})
      assert {[{"op.ack", %{"id" => ^id}}], %{}} = Machines.snapshot("mm1", result, routes)

      assert {:finished, %{"status" => "completed", "state" => %{"result" => %{"out" => "hi"}}}} =
               Machines.op_state(id)

      assert Durable.signal_payload(key) == %{"status" => "finished"}

      # A second copy is acked again and changes nothing.
      assert {[{"op.ack", _}], _} = Machines.snapshot("mm1", result, %{})
      assert {[{"op.cancel", _}], _} = Machines.snapshot("mm1", snapshot(id, "awaiting"), %{})
      assert {:finished, _} = Machines.op_state(id)
    end

    @tag capture_log: true
    test "another machine's op is ignored; an unknown op is acked or canceled" do
      {_task, %{id: id}} = started("mm1")

      assert {[], _} = Machines.snapshot("mm2", snapshot(id, "completed"), %{})
      assert Machines.op_state(id) == {:open, false}

      assert {[{"op.ack", %{"id" => "op_nothing"}}], _} =
               Machines.snapshot("mm2", snapshot("op_nothing", "failed"), %{})

      assert {[{"op.cancel", %{"id" => "op_nothing"}}], _} =
               Machines.snapshot("mm2", snapshot("op_nothing", "awaiting"), %{})
    end

    @tag capture_log: true
    test "a payload that doesn't parse is dropped" do
      assert Machines.snapshot("mm1", %{"op" => %{"id" => "../etc"}}, %{a: 1}) == {[], %{a: 1}}
    end
  end

  describe "claim_tx/2 (hub rule 8)" do
    test "takes a finished op's result and closes the row without it" do
      {_task, %{id: id}} = started("mm1")
      finish("mm1", id)

      assert %{"status" => "completed"} = Durable.commit(&Machines.claim_tx(&1, id))
      assert %Op{status: "closed", result: nil} = row(id)
      assert Machines.op_state(id) == :closed
      assert Durable.commit(&Machines.claim_tx(&1, id)) == nil
    end
  end

  describe "cancel_tx/2 (hub rule 7)" do
    test "an open row gets cancel, and op.cancel goes to a connected machine" do
      {_task, %{id: id}} = started("mm1")
      :ok = Durable.commit(&Machines.cancel_tx(&1, id))
      assert row(id).cancel
      refute_received {:command, _, _}

      {_task, %{id: other}} = started("mm1")
      :ok = connect("mm1")
      :ok = Durable.commit(&Machines.cancel_tx(&1, other))
      assert_received {:command, "op.cancel", %{"id" => ^other}}
    end

    test "a join resends op.cancel for a canceled row, and never op.start" do
      {_task, %{id: id}} = started("mm1")
      :ok = Durable.commit(&Machines.cancel_tx(&1, id))

      assert Machines.joined("mm1") == [{"op.cancel", %{"id" => id}}]
      refute row(id).pushed
    end

    test "a result that came in first is closed and dropped" do
      {_task, %{id: id}} = started("mm1")
      finish("mm1", id)

      :ok = Durable.commit(&Machines.cancel_tx(&1, id))
      assert %Op{status: "closed", result: nil} = row(id)
    end

    test "a canceled row's result closes it with no snapshot kept" do
      {_task, %{id: id}} = started("mm1")
      :ok = Durable.commit(&Machines.cancel_tx(&1, id))
      finish("mm1", id)

      assert %Op{status: "closed", result: nil, confirmed: true} = row(id)
      assert Durable.signal_payload(Machines.signal_key(id)) == %{"status" => "closed"}
    end

    test "nothing for an op with no row" do
      assert Durable.commit(&Machines.cancel_tx(&1, "op_nothing")) == :ok
    end
  end

  describe "abandon_tx/2 (hub rule 7)" do
    test "an op never pushed or confirmed, on an offline machine" do
      {_task, %{id: id}} = started("mm1")

      assert Durable.commit(&Machines.abandon_tx(&1, id)) ==
               {:abandoned, %{pushed: false, confirmed: false, online: false}}

      assert row(id).cancel
    end

    test "with the machine connected again, it sends op.cancel and says so" do
      {_task, %{id: id}} = started("mm1")
      [_start] = Machines.joined("mm1")
      :ok = connect("mm1")

      assert Durable.commit(&Machines.abandon_tx(&1, id)) ==
               {:abandoned, %{pushed: true, confirmed: false, online: true}}

      assert_received {:command, "op.cancel", %{"id" => ^id}}
    end

    test "an op that finished meanwhile is claimed instead" do
      {_task, %{id: id}} = started("mm1")
      finish("mm1", id)

      assert {:claimed, %{"status" => "completed"}} = Durable.commit(&Machines.abandon_tx(&1, id))
      assert %Op{status: "closed", result: nil, cancel: false} = row(id)
    end
  end

  describe "output/3" do
    test "broadcasts tool_output on the conversation's topic and caches the route" do
      {task, %{id: id, call_id: call_id}} = started("mm1")
      c = task.conversation_id
      Durable.subscribe(c)

      payload = %{"id" => id, "stream" => "out", "text" => "hello\n"}
      routes = Machines.output("mm1", payload, %{})
      assert routes == %{id => {c, call_id}}

      assert_receive {:live, ^c,
                      %{
                        "type" => "tool_output",
                        "call_id" => ^call_id,
                        "stream" => "out",
                        "text" => "hello\n"
                      }}

      # A terminal snapshot drops the route.
      assert {_pushes, %{}} = Machines.snapshot("mm1", snapshot(id, "completed"), routes)
    end

    test "drops output for another machine's op, an unknown op, or one that has ended" do
      {task, %{id: id}} = started("mm1")
      Durable.subscribe(task.conversation_id)

      assert Machines.output("mm2", %{"id" => id, "stream" => "out", "text" => "x"}, %{}) == %{}

      assert Machines.output("mm1", %{"id" => "op_none", "stream" => "out", "text" => "x"}, %{}) ==
               %{}

      finish("mm1", id)
      assert Machines.output("mm1", %{"id" => id, "stream" => "err", "text" => "x"}, %{}) == %{}
      assert Machines.output("mm1", %{"id" => id, "stream" => "bad"}, %{}) == %{}
      refute_received {:live, _, _}
    end
  end
end
