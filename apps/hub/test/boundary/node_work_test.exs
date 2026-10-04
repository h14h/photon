defmodule Photon.NodeWorkTest do
  @moduledoc """
  Regression tests for how a node's answer reaches the assistant's
  conversation, each named after the verification finding it pins (see
  docs/verification.md).
  """

  use Photon.DataCase, async: false

  alias Photon.{Assistant, NodeSessions}
  alias Photon.Durable.{Runtime, Submission, TaskRecord, ToolTask, Tx}
  alias PhotonCore.Message

  @moduletag :durable

  # A run_on_node call parked in "resume" under a waiting run, as it is once
  # the node has answered, plus its watcher. The scheduler is stopped, so the
  # test runs the steps itself.
  defp parked_call(opts) do
    stop_supervised!(Photon.Durable.Scheduler)
    c = Assistant.conversation_id()

    Durable.commit(fn tx ->
      run =
        Tx.create_task(tx, %{
          kind: "generation",
          conversation_id: c,
          phase: "after_tools",
          waiting: %{"signal" => "never"}
        })

      watcher =
        Tx.create_task(tx, %{
          kind: "node_watch",
          conversation_id: c,
          background: true,
          request_id: "watch:in_x",
          input: %{"session_id" => "ns_x", "input_id" => "in_x", "node" => "box", "title" => "t"},
          waiting: %{"signal" => "node_input:in_x"}
        })

      watcher =
        if opts[:reported] do
          Durable.submit_tx(tx, c, "[Report from box] done", request_id: "report:in_x")
          Tx.update_task(tx, watcher, status: "done")
        else
          watcher
        end

      state = %{
        "session_id" => "ns_x",
        "input_id" => "in_x",
        "watcher" => watcher.id,
        "node" => "box",
        "title" => "t"
      }

      call = %{"id" => "call_1", "name" => "run_on_node", "arguments" => "{}"}

      tool =
        Tx.create_task(tx, %{
          kind: "tool",
          conversation_id: c,
          owner_task_id: run.id,
          phase: "resume",
          input: %{"call" => call},
          checkpoint: %{"state" => state}
        })

      tool =
        Tx.update_task(tx, tool,
          status: "running",
          runs: 1,
          abort_requested: opts[:stopped] || false
        )

      Tx.signal(tx, "node_input:in_x", %{
        "session_id" => "ns_x",
        "answer" => "the node's answer",
        "failure" => nil
      })

      %{conversation: c, tool: tool, watcher: watcher}
    end)
  end

  defp tool_results(c), do: texts(c, "tool_result")

  describe "a resumed call (Durable F1, F2)" do
    # Durable F1: the answer came back in the tool result and again in the
    # watcher's report.
    test "an answer already reported by the watcher isn't repeated in the tool result" do
      %{conversation: c, tool: tool} = parked_call(reported: true)
      ToolTask.step("resume", tool, %Runtime{task: tool})

      assert [result] = tool_results(c)
      refute result =~ "the node's answer"
      assert result =~ "report"
    end

    test "an answer the watcher hasn't reported comes back in the result, and the watcher stops" do
      %{conversation: c, tool: tool, watcher: watcher} = parked_call([])
      ToolTask.step("resume", tool, %Runtime{task: tool})

      assert [result] = tool_results(c)
      assert result =~ "the node's answer"
      assert Repo.get(TaskRecord, watcher.id).abort_requested
    end

    # Durable F2: a Stop between the watcher abort (its own commit) and the
    # tool result lost the answer.
    test "a stopped call leaves its watcher alone, so the answer is still reported" do
      %{conversation: c, tool: tool, watcher: watcher} = parked_call(stopped: true)
      assert ToolTask.step("resume", tool, %Runtime{task: tool}) == :ignored

      assert tool_results(c) == []
      refute Repo.get(TaskRecord, watcher.id).abort_requested
    end
  end

  describe "a call interrupted after it handed work to a node (Durable F3)" do
    # Durable F3: a Stop (or a crash) after the session started but before the
    # watcher existed left node work nobody would report.
    test "a call stopped after it started node work leaves a watcher" do
      stop_supervised!(Photon.Durable.Scheduler)
      c = Assistant.conversation_id()

      tool =
        Durable.commit(fn tx ->
          Tx.create_task(tx, %{
            kind: "tool",
            conversation_id: c,
            phase: "run",
            input: %{"call" => %{"id" => "call_1", "name" => "run_on_node", "arguments" => "{}"}}
          })
        end)

      "t_" <> suffix = tool.id

      {:ok, _session, _input} =
        NodeSessions.start("box", "do it", id: "ns_" <> suffix, input_id: "in_" <> suffix)

      Durable.commit(&ToolTask.on_abort(tool, &1))

      assert %TaskRecord{kind: "node_watch", status: "pending", input: %{"session_id" => session}} =
               Repo.get_by(TaskRecord, request_id: "watch:in_" <> suffix)

      assert session == "ns_" <> suffix
    end
  end

  describe "Stop and crashes (Durable F6, F9)" do
    # Durable F6: Stop withdrew queued node reports along with the user's input.
    test "Stop withdraws the user's queued messages but keeps node reports" do
      stop_supervised!(Photon.Durable.Scheduler)
      c = Assistant.conversation_id()

      Durable.commit(
        &Tx.create_task(&1, %{
          kind: "generation",
          conversation_id: c,
          phase: "after_tools",
          waiting: %{"signal" => "never"}
        })
      )

      {:ok, mine} = Assistant.send("and also this")

      {:ok, report} =
        Durable.submit(c, "[Report from box] done", source: %{"kind" => "node_report"})

      assert {mine.status, report.status} == {"queued", "queued"}

      Assistant.stop()
      assert Repo.get(Submission, mine.id).status == "withdrawn"
      assert Repo.get(Submission, report.id).status == "queued"
    end

    # Durable F9: a watcher whose step crashed failed for good, and the report
    # never came.
    @tag capture_log: true
    test "a watcher whose step keeps crashing still reports the answer" do
      c = Assistant.conversation_id()
      Durable.subscribe(c)

      Durable.signal("node_input:in_y", %{
        "session_id" => "ns_y",
        "answer" => "it worked",
        "failure" => nil
      })

      Durable.create_task(%{
        kind: "node_watch",
        conversation_id: c,
        background: true,
        request_id: "watch:in_y",
        phase: "no such phase",
        input: %{"session_id" => "ns_y", "input_id" => "in_y", "node" => "box", "title" => "t"}
      })

      report = await_entry(c, &(&1.data["source"]["kind"] == "node_report"), 10_000)
      assert Message.text_of(report.data["message"]) =~ "it worked"
    end
  end

  describe "a watcher's deadline" do
    test "a watcher whose node never answers says it stopped waiting" do
      c = Assistant.conversation_id()
      Durable.subscribe(c)

      Durable.create_task(%{
        kind: "node_watch",
        conversation_id: c,
        background: true,
        request_id: "watch:in_z",
        phase: "report",
        input: %{"session_id" => "ns_z", "input_id" => "in_z", "node" => "box", "title" => "t"},
        waiting: %{"signal" => "node_input:in_z", "until" => 0}
      })

      report = await_entry(c, &(&1.data["source"]["kind"] == "node_report"), 10_000)
      assert Message.text_of(report.data["message"]) =~ "the hub stopped waiting"
      assert report.data["source"]["failed"]
    end
  end
end
