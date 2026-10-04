defmodule PhotonNode.Harness.RecoveryTest do
  @moduledoc """
  Regression tests for the session coordinator's recovery and stop paths,
  each named after the verification finding it pins (see docs/verification.md).
  """

  use PhotonNode.HarnessCase, async: false

  alias PhotonCore.Message
  alias PhotonNode.Harness.{Context, Coordinator, Ops, Store}
  alias PhotonNode.TestScript

  defp kinds(records), do: Enum.map(records, & &1["kind"])

  # Runs Harness.deliver/3 in another process once the test has started
  # tracing it, and waits until it has sent its message to `coordinator`.
  defp deliver_traced(session_id, input, coordinator) do
    test = self()

    deliverer =
      spawn(fn ->
        receive do
          :go -> send(test, {:delivered, Harness.deliver(session_id, input)})
        end
      end)

    :erlang.trace(deliverer, true, [:send])
    send(deliverer, :go)
    assert_receive {:trace, ^deliverer, :send, _message, ^coordinator}, 5_000
    :erlang.trace(deliverer, false, [:send])
    deliverer
  end

  # The same for Harness.stop/1.
  defp stop_traced(session_id, coordinator) do
    test = self()

    stopper =
      spawn(fn ->
        receive do
          :go -> send(test, {:stop_returned, Harness.stop(session_id)})
        end
      end)

    :erlang.trace(stopper, true, [:send])
    send(stopper, :go)
    assert_receive {:trace, ^stopper, :send, _message, ^coordinator}, 5_000

    # A stop that doesn't wait for an answer has already returned.
    try do
      :erlang.trace(stopper, false, [:send])
    rescue
      ArgumentError -> :ok
    end

    stopper
  end

  # A log with one Bash call whose operation is recorded as ready (never
  # started), as a coordinator that crashed before dispatching it leaves it.
  # Returns the file the command creates.
  defp ready_shell_log(session_id, workspace) do
    File.mkdir_p!(workspace)
    marker = Path.join(workspace, "ran-#{session_id}")
    command = "touch #{marker}"

    op =
      shell_op(
        id: "op_" <> session_id,
        command: command,
        workspace: workspace,
        dir: Store.operations_dir(session_id)
      )

    write_log(session_id, %{}, [
      {"input", message("$ " <> command)},
      {"turn", %{"id" => "turn_a", "previous" => "", "type" => "regular"}},
      {"model_response",
       response_data("turn_a", Message.assistant("Running.", [bash_call("c1", command)]))},
      {"tool_call_status",
       %{
         "turn_id" => "turn_a",
         "call_id" => "c1",
         "status" => %{"error" => "", "waiting_for" => [op["id"]]},
         "operations" => [op]
       }},
      {"state", %{"state" => "running"}}
    ])

    marker
  end

  defp ops_in_log(session_id) do
    for %{"kind" => "tool_call_status", "data" => %{"operations" => ops}} <-
          Store.read(session_id),
        op <- ops,
        do: op
  end

  defp final_operations(records) do
    records
    |> Enum.filter(&match?(%{"kind" => "tool_call_status"}, &1))
    |> List.last()
    |> get_in(["data", "operations"])
  end

  describe "input delivery" do
    # NS-3 / Coordinator F6: inputs in a crashed coordinator's mailbox were lost.
    test "an input in the mailbox of a coordinator that crashes still reaches the log" do
      :ok = Harness.deliver("d1", message("help"))
      await_record("d1", &idle?/1)

      coordinator = Coordinator.whereis("d1")
      :sys.suspend(coordinator)
      second = message("$ echo second input")
      deliver_traced("d1", second, coordinator)
      Process.exit(coordinator, :kill)

      assert_receive {:delivered, :ok}, 10_000
      records = await_record("d1", &idle?/1)
      assert %{"data" => %{"id" => id}} = Enum.find(records, &(&1["kind"] == "input"))
      assert id == second["id"]
      assert answer(records) =~ "second input"
    end

    # NS-4 / Coordinator F5: an input queued behind :idle_stop died with the process.
    test "an input that reaches a coordinator as it stops for idleness still reaches the log" do
      :ok = Harness.deliver("d2", message("help"))
      await_record("d2", &idle?/1)

      coordinator = Coordinator.whereis("d2")
      ref = Process.monitor(coordinator)
      :sys.suspend(coordinator)
      send(coordinator, :idle_stop)
      second = message("$ echo after idle")
      deliver_traced("d2", second, coordinator)
      :sys.resume(coordinator)

      assert_receive {:DOWN, ^ref, :process, ^coordinator, :normal}, 5_000
      assert_receive {:delivered, :ok}, 10_000
      records = await_record("d2", &idle?/1)
      assert answer(records) =~ "after idle"
    end

    # NS-2 / Coordinator F7: resume_all skipped a session whose input was
    # logged before its "running" record.
    test "a session with logged input it never started on is resumed on boot" do
      write_log("d3", %{}, [{"input", message("help")}])

      :ok = Harness.resume_all()
      records = await_record("d3", &idle?/1)
      assert "turn" in kinds(records)
      assert answer(records) =~ "mock model"
    end
  end

  describe "hard stops" do
    # NS-8 / Coordinator F2 / node-stop-lost-on-crash: a logged hard stop
    # without its "stopped" record was forgotten on restart.
    test "a hard stop recorded before a restart still ends the work", %{workspace: workspace} do
      File.mkdir_p!(workspace)
      marker = Path.join(workspace, "ran")
      command = "touch #{marker}"

      op =
        shell_op(
          id: "op_s1",
          command: command,
          workspace: workspace,
          dir: Store.operations_dir("h1")
        )

      stop = %{
        "id" => "stop_1",
        "kind" => "control",
        "payload" => %{"mode" => "hard", "reason" => "x"}
      }

      write_log("h1", %{}, [
        {"input", message("$ " <> command)},
        {"turn", %{"id" => "turn_a", "previous" => "", "type" => "regular"}},
        {"model_response",
         response_data("turn_a", Message.assistant("Running.", [bash_call("c1", command)]))},
        {"tool_call_status",
         %{
           "turn_id" => "turn_a",
           "call_id" => "c1",
           "status" => %{"error" => "", "waiting_for" => ["op_s1"]},
           "operations" => [op]
         }},
        {"state", %{"state" => "running"}},
        {"input", stop}
      ])

      :ok = Harness.resume_all()
      records = await_record("h1", &stopped?/1)
      refute "turn" in kinds(records)
      refute File.exists?(marker)

      assert Enum.any?(records, &final_status?(&1, "canceled"))
    end

    # Coordinator F4: an input accepted while a hard stop was finishing was
    # marked delivered by "stopped" and never answered.
    test "an input that arrives while a stop is finishing is answered after it" do
      :ok = Harness.deliver("h2", message("sleep 30"))
      records = await_record("h2", &running_op?/1)
      %{"data" => %{"state" => %{"pgid" => pgid}}} = List.last(records)

      coordinator = Coordinator.whereis("h2")
      :sys.suspend(coordinator)
      stop_traced("h2", coordinator)
      second = message("$ echo after the stop")
      deliver_traced("h2", second, coordinator)
      :sys.resume(coordinator)

      stopping = await_record("h2", &stopped?/1)

      refute Enum.any?(
               stopping,
               &match?(%{"kind" => "input", "data" => %{"kind" => "external"}}, &1)
             ),
             "the new input was folded into the stop"

      after_stop = await_record("h2", &idle?/1)
      assert hd(after_stop)["kind"] == "input"
      assert answer(after_stop) =~ "after the stop"
      assert_receive {:stop_returned, :ok}
      assert_receive {:delivered, :ok}
      kill_group(pgid)
    end

    # NS-9: the hub's stop was a plain message, lost with the mailbox of a
    # coordinator that crashed before handling it; the restarted coordinator
    # carried on with the work.
    test "a stop in the mailbox of a coordinator that crashes still stops the work" do
      :ok = Harness.deliver("h3", message("sleep 30"))
      records = await_record("h3", &running_op?/1)
      %{"data" => %{"state" => %{"pgid" => pgid}}} = List.last(records)
      on_exit(fn -> kill_group(pgid) end)

      coordinator = Coordinator.whereis("h3")
      :sys.suspend(coordinator)
      stop_traced("h3", coordinator)
      Process.exit(coordinator, :kill)

      assert_receive {:stop_returned, :ok}, 10_000
      records = await_record("h3", &stopped?/1)
      refute Enum.any?(records, &idle?/1)

      assert Enum.any?(
               records,
               &match?(%{"kind" => "input", "data" => %{"payload" => %{"mode" => "hard"}}}, &1)
             )
    end

    # NS-9: a stop for a session whose coordinator wasn't running (it was
    # about to be restarted, or the node hadn't resumed it yet) was dropped,
    # though its log said it was working.
    test "a stop for a working session with no coordinator running still stops it",
         %{workspace: workspace} do
      File.mkdir_p!(workspace)

      op =
        shell_op(
          id: "op_s3",
          command: "sleep 30",
          workspace: workspace,
          dir: Store.operations_dir("h4")
        )

      write_log("h4", %{}, [
        {"input", message("$ sleep 30")},
        {"turn", %{"id" => "turn_a", "previous" => "", "type" => "regular"}},
        {"model_response",
         response_data("turn_a", Message.assistant("Running.", [bash_call("c1", "sleep 30")]))},
        {"tool_call_status",
         %{
           "turn_id" => "turn_a",
           "call_id" => "c1",
           "status" => %{"error" => "", "waiting_for" => ["op_s3"]},
           "operations" => [op]
         }},
        {"state", %{"state" => "running"}}
      ])

      assert Coordinator.whereis("h4") == nil
      :ok = Harness.stop("h4")
      records = await_record("h4", &stopped?/1)
      refute Enum.any?(records, &idle?/1)

      assert Enum.any?(records, &final_status?(&1, "canceled"))
    end

    test "a stop for a session that isn't working starts nothing" do
      write_log("h5", %{}, [
        {"input", message("help")},
        {"turn", %{"id" => "turn_a", "previous" => "", "type" => "regular"}},
        {"state", %{"state" => "running"}},
        {"model_response", response_data("turn_a", Message.assistant("Done."))},
        {"state", %{"state" => "idle", "answer" => "Done."}}
      ])

      :ok = Harness.stop("h5")
      assert Coordinator.whereis("h5") == nil
      refute_received {:event, "h5", _, _}
    end
  end

  describe "processes the coordinator starts" do
    # Coordinator F1: a model request outlived a coordinator that crashed
    # while it ran, and the restart started a second one.
    test "the model request dies with its coordinator" do
      TestScript.use_script()
      :ok = Harness.deliver("p1", message("block"))
      assert_receive {:llm_request, task}, 5_000

      ref = Process.monitor(task)
      Process.exit(Coordinator.whereis("p1"), :kill)
      assert_receive {:DOWN, ^ref, :process, ^task, _}, 5_000
    end

    # Coordinator F9: a crashed operation process went unnoticed and its
    # call never got a result.
    test "an operation process that crashes fails its operation" do
      :ok = Harness.deliver("p2", message("sleep 30"))
      records = await_record("p2", &running_op?/1)
      %{"data" => %{"id" => op_id, "state" => %{"pgid" => pgid}}} = List.last(records)
      [{op_pid, _}] = Registry.lookup(PhotonNode.OpRegistry, op_id)

      Process.exit(op_pid, :kill)
      records = await_record("p2", &idle?/1)
      kill_group(pgid)

      assert Enum.any?(records, &final_status?(&1, "failed"))
    end

    # Registry.lookup/2 still returns a process that has just exited until
    # the registry handles its exit. Ops.add/2 sent such a process :resend
    # and the coordinator monitored it, got :noproc, and failed an
    # operation whose command never ran.
    test "an operation whose old process has just exited is started again, not failed",
         %{workspace: workspace} do
      marker = ready_shell_log("p3", workspace)

      partition = Module.safe_concat(PhotonNode.OpRegistry, "PIDPartition0")
      :sys.suspend(partition)
      on_exit(fn -> if Process.whereis(partition), do: :sys.resume(partition) end)

      # A process for the operation that stopped without starting the
      # command (no coordinator confirmed its checkpoint). With the registry
      # held back, its entry outlives it.
      {:ok, pid} = Ops.add(Enum.at(ops_in_log("p3"), 0), "p3")
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
      assert [{^pid, _}] = Registry.lookup(PhotonNode.OpRegistry, "op_p3")

      :ok = Harness.resume_all()
      records = await_record("p3", &idle?/1)
      :sys.resume(partition)

      assert [%{"status" => "completed"}] = final_operations(records)
      assert File.exists?(marker)
    end

    # The coordinator monitors an operation process only after Ops.add/2
    # returns it, so one that exits in between is seen as :noproc. That is
    # no crash, so the operation isn't failed: it is dispatched again (here
    # it finds the process still running).
    test "an operation process already gone when monitored isn't taken for a crash",
         %{workspace: workspace} do
      File.mkdir_p!(workspace)
      go = Path.join(workspace, "go")
      :ok = Harness.deliver("p4", message("$ while [ ! -f #{go} ]; do sleep 0.05; done"))
      records = await_record("p4", &running_op?/1)
      %{"data" => %{"id" => op_id}} = List.last(records)

      coordinator = Coordinator.whereis("p4")
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}

      :sys.replace_state(coordinator, fn state ->
        %{state | op_monitors: Map.put(state.op_monitors, ref, {op_id, dead})}
      end)

      send(coordinator, {:DOWN, ref, :process, dead, :noproc})
      _ = :sys.get_state(coordinator)
      File.write!(go, "")

      records = await_record("p4", &idle?/1)
      assert [%{"status" => "completed"}] = final_operations(records)
    end
  end

  # Coordinator F10: a recorded call whose tool no longer resolved never
  # finished, and every reconcile recorded its result again.
  test "a call whose tool is no longer available still gets one result", %{workspace: workspace} do
    File.mkdir_p!(workspace)

    op =
      shell_op(
        id: "op_v1",
        command: "true",
        workspace: workspace,
        dir: Store.operations_dir("v1")
      )

    done = %{
      op
      | "status" => "completed",
        "state" => Map.put(op["state"], "result", %{"out" => "", "err" => "", "exit_code" => 0})
    }

    write_log("v1", %{"disallowed_tools" => ["Bash"]}, [
      {"input", message("help")},
      {"turn", %{"id" => "turn_a", "previous" => "", "type" => "regular"}},
      {"model_response",
       response_data("turn_a", Message.assistant("Running.", [bash_call("c1", "true")]))},
      {"tool_call_status",
       %{
         "turn_id" => "turn_a",
         "call_id" => "c1",
         "status" => %{"error" => "", "waiting_for" => ["op_v1"]},
         "operations" => [op]
       }},
      {"operation", done},
      {"state", %{"state" => "running"}}
    ])

    :ok = Harness.resume_all()
    await_record("v1", &idle?/1)

    statuses =
      for %{"kind" => "tool_call_status", "data" => %{"call_id" => "c1"}} = r <- Store.read("v1"),
          do: r

    assert length(statuses) == 2
    ctx = :sys.get_state(Coordinator.whereis("v1")).session.ctx

    assert Enum.any?(
             Context.build(ctx),
             &(Message.text_of(&1) =~ "no longer available")
           )
  end

  # NS-6: a run whose last response had no text reported the previous run's answer.
  test "a run that ends without text doesn't report an earlier run's answer" do
    TestScript.use_script()
    :ok = Harness.deliver("a1", message("$ echo first answer"))
    assert answer(await_record("a1", &idle?/1)) =~ "first answer"

    :ok = Harness.deliver("a1", message("quiet"))
    assert answer(await_record("a1", &idle?/1)) == nil
  end
end
