defmodule Photon.NodeSessions.MirrorTest do
  @moduledoc "The rules of the hub's copy of a node session."

  use Photon.Case, async: true

  describe "a record from the node" do
    test "is stored only at the next offset the hub expects" do
      s = session(next_offset: 3)

      assert Mirror.place(s, "box", 3) == :next
      assert Mirror.place(s, "box", 1) == :duplicate
      assert Mirror.place(s, "box", 7) == {:gap, 3}
    end

    test "from another node, or for an unknown session, is ignored" do
      assert Mirror.place(session(), "intruder", 0) == :ignored
      assert Mirror.place(nil, "box", 0) == :ignored
    end

    test "that isn't an object is stored wrapped, so offsets stay in step" do
      assert Mirror.normalize([1, 2]) == %{"kind" => "invalid", "data" => [1, 2]}
      assert Mirror.normalize(%{"kind" => "turn"}) == %{"kind" => "turn"}
    end
  end

  describe "what a record changes" do
    test "an input record accepts that input" do
      assert Mirror.effect(input_record("in_7")) == {:accept_input, "in_7"}
    end

    test "an input record the hub can't use changes nothing" do
      assert Mirror.effect(record("input", %{"id" => nil})) == :none
      assert Mirror.effect(record("input", %{"id" => 7})) == :none
    end

    test "running marks the session running" do
      assert Mirror.effect(state_record("running")) == {:status, %{status: "running"}}
    end

    test "idle settles accepted inputs with the session's answer or failure" do
      assert Mirror.effect(state_record("idle", %{"answer" => "42"})) ==
               {:settle, %{status: "idle", last_answer: "42", last_failure: nil}, "42", nil}

      assert {:settle, %{last_failure: "HTTP 500"}, nil, "HTTP 500"} =
               Mirror.effect(state_record("idle", %{"failure" => %{"message" => "HTTP 500"}}))

      assert {:settle, _, nil, "plain"} =
               Mirror.effect(state_record("idle", %{"failure" => "plain"}))
    end

    test "stopped settles them as stopped, with a default answer" do
      assert Mirror.effect(state_record("stopped")) ==
               {:settle,
                %{
                  status: "stopped",
                  last_answer: "Stopped before finishing.",
                  last_failure: "stopped"
                }, "Stopped before finishing.", "stopped"}

      assert {:settle, _, "partial", "stopped"} =
               Mirror.effect(state_record("stopped", %{"answer" => "partial"}))
    end

    test "fields of the wrong type are ignored (hub-ingest-raises-on-malformed-record)" do
      assert {:settle, %{last_answer: nil, last_failure: nil}, nil, nil} =
               Mirror.effect(
                 state_record("idle", %{"answer" => %{"x" => 1}, "failure" => %{"message" => 3}})
               )
    end

    test "other records change nothing but the copy" do
      assert Mirror.effect(record("turn")) == :none
      assert Mirror.effect(Mirror.normalize("junk")) == :none
    end
  end

  describe "a refused input" do
    test "fails only while it is queued, for the session that refused it" do
      assert Mirror.rejectable?(input(), "ns_1")
      refute Mirror.rejectable?(input(state: "accepted"), "ns_1")
      refute Mirror.rejectable?(input(), "ns_other")
      refute Mirror.rejectable?(nil, "ns_1")
    end

    test "fails a session that never started, and leaves a running one alone" do
      assert Mirror.refused_session(session(status: "pending"), input(), "bad workspace") ==
               %{status: "failed", last_failure: "bad workspace"}

      assert Mirror.refused_session(session(status: "running"), input(), "bad workspace") == nil
      assert Mirror.refused_session(nil, input(), "x") == nil
    end

    test "a refused stop changes nothing about the session, even one still pending" do
      stop = input(input: Mirror.stop_input("stop_1"))
      assert Mirror.refused_session(session(status: "pending"), stop, "nothing to stop") == nil
    end

    test "keeps its reason as text" do
      assert Mirror.reason_text("nope") == "nope"
      assert Mirror.reason_text(%{"code" => 1}) == ~s(%{"code" => 1})
    end
  end

  describe "what the hub stores and sends" do
    test "a new session is pending, titled from its prompt" do
      assert %{
               id: "ns_1",
               node_id: "box",
               title: "check the disks",
               origin: "user",
               status: "pending",
               next_offset: 0
             } = Mirror.session("ns_1", "box", "  check   the\ndisks ", [], at())

      assert %{title: "Mine", origin: "assistant"} =
               Mirror.session("ns_1", "box", "x", [title: "Mine", origin: "assistant"], at())
    end

    test "a long prompt's title is cut at 60 characters" do
      title = Mirror.title(String.duplicate("a", 80))
      assert String.length(title) == 60
      assert String.ends_with?(title, "...")
    end

    test "an input goes out with the session's model settings" do
      input = Mirror.external_input("in_1", "hi")

      assert input == %{
               "id" => "in_1",
               "kind" => "external",
               "payload" => %{"content" => [%{"type" => "text", "text" => "hi"}]}
             }

      assert %{state: "queued", session_id: "ns_1"} =
               Mirror.queued_input("in_1", "ns_1", input, at())

      assert Mirror.input_command(session(), input) ==
               %{"session_id" => "ns_1", "input" => input, "config" => session().config}
    end

    test "a settled input's signal carries the answer and failure" do
      assert Mirror.signal_key("in_1") == "node_input:in_1"

      assert Mirror.signal_payload("ns_1", "42", nil) ==
               %{"session_id" => "ns_1", "answer" => "42", "failure" => nil}
    end
  end
end
