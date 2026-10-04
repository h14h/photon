defmodule PhotonNode.HarnessTest do
  @moduledoc """
  The harness API (`PhotonNode.Harness`) end to end: a real node, real
  files, real commands and the mock model. The rules a session follows are
  tested on the core (`test/core/session_test.exs`); these check that the
  processes, the log and the commands behave as a client sees them.
  """

  use PhotonNode.HarnessCase, async: false

  alias PhotonNode.Harness.{Coordinator, Store}

  describe "delivering input" do
    test "runs a command and reports its output" do
      :ok = Harness.deliver("s1", message("$ echo hello from the node"))
      records = await_record("s1", &idle?/1)

      kinds = Enum.map(records, & &1["kind"])
      assert hd(kinds) == "session"
      assert "turn" in kinds and "model_response" in kinds and "tool_call_status" in kinds
      assert answer(records) =~ "hello from the node"

      # The first status carries the new operation; a later one its result.
      [first | _] = statuses = for %{"kind" => "tool_call_status"} = r <- records, do: r["data"]
      assert [%{"status" => "ready"}] = first["operations"]

      assert [%{"status" => "completed", "state" => %{"result" => %{"exit_code" => 0}}}] =
               List.last(statuses)["operations"]
    end

    test "a repeated input ID is ignored" do
      input = message("$ echo once")
      :ok = Harness.deliver("s2", input)
      await_record("s2", &idle?/1)
      :ok = Harness.deliver("s2", input)
      _ = :sys.get_state(Coordinator.whereis("s2"))

      inputs =
        for %{"kind" => "input", "data" => %{"kind" => "external"}} <- Store.read("s2"), do: 1

      assert length(inputs) == 1
    end

    test "an asynchronous command's result wakes a later turn" do
      :ok = Harness.deliver("s3", message("sleep 2"))
      records = await_record("s3", &idle?/1)

      turns = Enum.count(records, &(&1["kind"] == "turn"))
      assert turns == 2
      assert answer(records) =~ "tick 2"
    end

    test "an unknown tool gets an error result and an immediate turn" do
      write_log("s6", %{}, [])

      :ok = Harness.deliver("s6", message("help"))
      records = await_record("s6", &idle?/1)
      assert answer(records) =~ "mock model"
    end

    test "input that isn't valid, or for a session that doesn't exist, is refused" do
      assert {:error, "invalid session id"} = Harness.deliver("bad id!", message("hi"))
      assert {:error, _} = Harness.deliver("s8", %{"id" => "x", "kind" => "nap"})
      assert {:error, "session s8 doesn't exist"} = Harness.deliver("s8", hard_stop())
    end
  end

  describe "a stop from the hub's outbox" do
    test "cancels running commands, and a repeat after a reconnect changes nothing" do
      :ok = Harness.deliver("s9", message("sleep 30"))
      await_record("s9", &running_op?/1)

      stop = hard_stop(%{"id" => "stop_hub"})
      :ok = Harness.deliver("s9", stop, %{"model" => "mock"})
      records = await_record("s9", &stopped?/1)
      assert Enum.any?(records, &final_status?(&1, "canceled"))

      :ok = Harness.deliver("s9", stop)
      stops = for %{"kind" => "input", "data" => %{"id" => "stop_hub"}} <- Store.read("s9"), do: 1
      assert stops == [1]
    end

    test "is refused when the session has nothing to stop" do
      :ok = Harness.deliver("s10", message("$ echo done"))
      await_record("s10", &idle?/1)

      assert {:error, "session s10 isn't working, so there's nothing to stop"} =
               Harness.deliver("s10", hard_stop())

      refute Enum.any?(Store.read("s10"), &match?(%{"data" => %{"kind" => "control"}}, &1))
    end
  end

  describe "commands" do
    test "stop cancels running commands" do
      :ok = Harness.deliver("s4", message("sleep 30"))
      await_record("s4", &running_op?/1)

      Harness.stop("s4")

      records = await_record("s4", &stopped?/1)
      assert Enum.any?(records, &final_status?(&1, "canceled"))
    end

    test "background children are killed when the command exits", %{workspace: workspace} do
      marker = "#{System.unique_integer([:positive])}.25"
      :ok = Harness.deliver("s5", message("$ (sleep #{marker} &) ; echo started"))
      await_record("s5", &idle?/1)

      {out, _} = System.cmd("pgrep", ["-f", "sleep #{marker}"])
      assert out == ""
      assert File.dir?(workspace)
    end
  end

  describe "resuming" do
    test "a session resumes a tool call recorded without a status" do
      input = message("$ echo resumed")
      call = %{"id" => "call_a", "name" => "Bash", "arguments" => ~s({"command":"echo resumed"})}

      write_log("s7", %{}, [
        {"input", input},
        {"turn", turn("turn_a")},
        {"model_response",
         %{
           "turn_id" => "turn_a",
           "response" => %{
             "message" => PhotonCore.Message.assistant("Running.", [call]),
             "stop" => "tool_use",
             "failure" => nil
           }
         }},
        {"state", %{"state" => "running"}}
      ])

      :ok = Harness.resume_all()
      records = await_record("s7", &idle?/1)
      assert answer(records) =~ "resumed"
    end
  end

  describe "deleting" do
    test "removes the log and stops the coordinator" do
      :ok = Harness.deliver("s9", message("help"))
      await_record("s9", &idle?/1)
      coordinator = Coordinator.whereis("s9")
      ref = Process.monitor(coordinator)

      :ok = Harness.delete("s9")

      assert_receive {:DOWN, ^ref, :process, ^coordinator, _}
      refute Store.exists?("s9")
    end
  end
end
