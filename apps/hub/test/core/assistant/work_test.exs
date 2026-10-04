defmodule Photon.Assistant.WorkTest do
  @moduledoc """
  The pure parts of the assistant's node work and its task kinds: IDs,
  waits, watchers, what a resumed call answers, and when a routine fires.
  The boundary tests (`test/boundary/node_work_test.exs`) run the same
  decisions through commits.
  """

  use Photon.Case, async: true

  alias Photon.Assistant.{NodeWatch, NodeWork, Routine}
  alias Photon.Durable.ToolAPI

  defp api(task_id \\ "t_abc"),
    do: ToolAPI.new(tool_task(call("run_on_node"), id: task_id))

  describe "node work" do
    test "takes its session and input IDs from the tool call's task, so a rerun finds them" do
      assert NodeWork.ids(api("t_abc")) == %{session_id: "ns_abc", input_id: "in_abc"}
    end

    test "waits 20 seconds unless asked, and never more than two minutes" do
      assert NodeWork.wait_seconds(nil) == 20
      assert NodeWork.wait_seconds(5) == 5
      assert NodeWork.wait_seconds(-3) == 0
      assert NodeWork.wait_seconds(600) == 120
    end

    test "has one background watcher per input, which knows the call that started it" do
      watcher = NodeWork.watcher(api(), session(), "in_abc")

      assert %{
               kind: "node_watch",
               conversation_id: "c_1",
               background: true,
               request_id: "watch:in_abc",
               phase: "start",
               input: %{"input_id" => "in_abc", "tool_task_id" => "t_abc", "node" => "box"}
             } = watcher
    end

    test "parks the call with what it needs to report" do
      assert NodeWork.parked(session(), "in_1", "t_w") == %{
               "session_id" => "ns_1",
               "input_id" => "in_1",
               "watcher" => "t_w",
               "node" => "box",
               "title" => "Check disks"
             }
    end
  end

  describe "a resumed call (Durable F1)" do
    setup do
      %{state: NodeWork.parked(session(), "in_1", "t_w")}
    end

    test "while the node hasn't answered, says it's still running", %{state: state} do
      assert {:running, {:ok, text, %{"status" => "running"}}} =
               NodeWork.resume_result(state, nil, false)

      assert text =~ "still running"
    end

    test "answers when no report was posted, so the watcher must stop", %{state: state} do
      assert {:answer, {:ok, text, %{"status" => "done", "session_id" => "ns_1"}}} =
               NodeWork.resume_result(state, signal("node_input:in_1", node_answer("42")), false)

      assert text == "box (session ns_1) finished:\n\n42"
    end

    test "points at the report when the watcher already posted it", %{state: state} do
      failed = signal("node_input:in_1", node_answer(nil, "boom"))

      assert {:reported, {:ok, text, %{"status" => "failed"}}} =
               NodeWork.resume_result(state, failed, true)

      assert text =~ "its report is in this conversation"
    end
  end

  describe "the watcher" do
    test "waits a day at most for the node's answer, counted from its creation" do
      day = 24 * 60 * 60 * 1000
      until = DateTime.to_unix(at(), :millisecond) + day

      assert NodeWatch.wait_for_signal(task(input: work())) ==
               {:wait, %{"signal" => "node_input:in_1", "until" => until}, "report", %{}}
    end

    test "waits for the call that started the work while it is live" do
      call = task(id: "t_9", kind: "tool", status: "waiting")

      assert NodeWatch.call_live?(call)
      refute NodeWatch.call_live?(%{call | status: "done"})
      refute NodeWatch.call_live?(%{call | abort_requested: true})
      refute NodeWatch.call_live?(nil)
      assert NodeWatch.wait_for_call(call) == {:wait, %{"on" => ["t_9"]}, "report", %{}}
    end

    test "reports with the shared report text" do
      assert NodeWatch.report(work(), node_answer("ok")) =~ "[Report from box]"
    end
  end

  describe "a routine" do
    defp routine(input, checkpoint \\ %{}) do
      task(id: "t_r", kind: "routine", phase: "fire", input: input, checkpoint: checkpoint)
    end

    test "first waits until its first time, counting runs from zero" do
      assert Routine.first_wait(routine(%{"first_at" => 1_000})) ==
               {:wait, %{"until" => 1_000}, "fire", %{"next_at" => 1_000, "runs" => 0}}

      assert {:wait, %{"until" => 5_000}, "fire", _} =
               Routine.first_wait(routine(%{"first_at" => 1_000}, %{"next_at" => 5_000}))
    end

    test "posts its prompt once per firing" do
      task = routine(%{"prompt" => "check disks"}, %{"runs" => 2})

      assert Routine.prompt(task) == "[Scheduled] check disks"
      assert Routine.request_id(task) == "routine:t_r:2"
    end

    test "a one-off finishes after it fires" do
      assert Routine.after_fire(routine(%{"every_ms" => nil}, %{"runs" => 0}), 0) ==
               {:done, %{"runs" => 1}}
    end

    test "a recurring one waits for its next time on its grid, skipping missed runs" do
      task = routine(%{"every_ms" => 100}, %{"next_at" => 1_000, "runs" => 3})

      assert Routine.after_fire(task, 1_050) ==
               {:wait, %{"until" => 1_100}, "fire", %{"next_at" => 1_100, "runs" => 4}}

      assert Routine.next_after(1_000, 100, 1_350) == 1_400
      assert Routine.next_after(1_000, 100, 500) == 1_100
    end
  end
end
