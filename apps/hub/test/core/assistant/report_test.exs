defmodule Photon.Assistant.ReportTest do
  @moduledoc "How node work's outcome reads, as a report and as a tool result."

  use Photon.Case, async: true

  @header ~s{[Report from box] "Check disks" (session ns_1)}

  describe "the watcher's report" do
    test "relays the answer" do
      assert Report.node_report(work(), node_answer("all good")) ==
               "#{@header} finished:\n\nall good"
    end

    test "says the work failed, with its last words when there are any" do
      assert Report.node_report(work(), node_answer("half done", "HTTP 500")) ==
               "#{@header} didn't finish: HTTP 500\n\nIts last words:\n\nhalf done"

      assert Report.node_report(work(), node_answer(nil, "stopped")) ==
               "#{@header} didn't finish: stopped"
    end

    test "says so when the work ended without a summary" do
      assert Report.node_report(work(), node_answer(nil)) ==
               "#{@header} finished without a summary."

      assert Report.node_report(work(), %{}) == "#{@header} finished without a summary."
    end

    test "is posted once per input, marked as a node report" do
      assert Report.request_id("in_1") == "report:in_1"
      assert Report.signal_key("in_1") == "node_input:in_1"

      assert Report.source(work(), node_answer("x", "boom")) == %{
               "kind" => "node_report",
               "node" => "box",
               "session_id" => "ns_1",
               "title" => "Check disks",
               "failed" => true
             }
    end

    test "after a watcher gave up says the hub lost track" do
      assert %{"failure" => failure, "answer" => nil} = Report.lost_track("boom")
      assert failure =~ "lost track of it (boom)"
    end
  end

  describe "the tool's result" do
    test "reads the same with a shorter header" do
      assert Report.tool_answer(work(), node_answer("all good")) ==
               "box (session ns_1) finished:\n\nall good"

      assert Report.tool_answer(work(), node_answer(nil, "boom")) ==
               "box (session ns_1) didn't finish: boom"
    end

    test "while the work runs, or once the report is posted, points at the report" do
      assert Report.still_running(work()) =~ "Started on box as session ns_1 and still running."
      assert Report.already_reported(work()) =~ "box (session ns_1) has finished"
    end

    test "carries a status for the page" do
      assert Report.status(node_answer("ok")) == "done"
      assert Report.status(node_answer(nil, "boom")) == "failed"
      assert Report.status(node_answer(nil, "")) == "done"
      refute Report.failed?(nil)
    end
  end
end
