defmodule Photon.NodeSessionsTest do
  @moduledoc """
  Regression tests for the hub's mirror of node sessions and its input
  outbox, through `Photon.NodeSessions`, each named after the verification
  finding it pins (see docs/verification.md). The rules themselves are
  tested on `Photon.NodeSessions.Mirror` in `test/core`.
  """

  use Photon.DataCase, async: false

  import Photon.Fixtures, only: [input_record: 1, record: 2, state_record: 2]

  alias Photon.NodeSessions

  @moduletag :durable

  ## Named setups

  defp started_session(_context) do
    {:ok, session, input} = NodeSessions.start("box", "hi")
    %{session: session, input: input}
  end

  # Stands in for a connected node: commands for it arrive here.
  defp connected_node(_context) do
    {:ok, _} = Registry.register(Photon.NodeRegistry, "box", %{"version" => "0"})
    :ok
  end

  describe "settling (NS-5)" do
    setup :started_session

    # NS-5 / Durable F5: ingest settled an input in one transaction and fired
    # its signal in a second commit; a hub that stopped in between never fired
    # it, and the node never resends a record the hub holds.
    test "an input is never settled without its signal", %{session: session, input: input} do
      :ok = NodeSessions.ingest(session.id, "box", 0, record("session", %{}))
      :ok = NodeSessions.ingest(session.id, "box", 1, input_record(input.id))

      # The durable store is down when the idle record arrives.
      stop_supervised!(Photon.Durable.Store)

      catch_exit(
        NodeSessions.ingest(session.id, "box", 2, state_record("idle", %{"answer" => "done"}))
      )

      start_supervised!(Photon.Durable.Store)

      settled? = NodeSessions.input(input.id).state == "done"
      signaled? = Durable.signal_payload("node_input:" <> input.id) != nil
      assert settled? == signaled?

      # The node replays from the hub's offset, and both happen together.
      offset = NodeSessions.get(session.id).next_offset
      assert offset == 2
      :ok = NodeSessions.ingest(session.id, "box", 2, state_record("idle", %{"answer" => "done"}))
      assert NodeSessions.input(input.id).state == "done"
      assert %{"answer" => "done"} = Durable.signal_payload("node_input:" <> input.id)
    end
  end

  describe "the outbox (NS-7)" do
    setup [:connected_node, :started_session]

    # NS-7: an input the node refused could be pushed again (a tool call
    # rerun sends the same ID), run on the node, and stay "failed" on the hub.
    test "an input the node refused is not pushed again", %{session: session, input: input} do
      assert_receive {:command, "input", %{"input" => %{"id" => id}}}
      assert id == input.id

      NodeSessions.reject_input(
        session.id,
        input.id,
        "workspace /nope is not a directory on this node",
        session.node_id
      )

      assert NodeSessions.input(input.id).state == "failed"
      assert NodeSessions.get(session.id).status == "failed"
      assert %{"failure" => "workspace" <> _} = Durable.signal_payload("node_input:" <> input.id)

      {:ok, again} = NodeSessions.send_input(session.id, "hi", input_id: input.id)
      assert again.state == "failed"
      refute_receive {:command, "input", _}
    end

    test "a message to an unknown session is refused" do
      assert NodeSessions.send_input("ns_nope", "hi") == {:error, "no session ns_nope"}
    end

    test "deleting a session tells the node and forgets it here", %{session: session} do
      assert_receive {:command, "input", _}
      :ok = NodeSessions.ingest(session.id, "box", 0, record("session", %{}))

      assert NodeSessions.delete(session.id) == :ok
      assert_receive {:command, "delete_session", %{"session_id" => id}}
      assert id == session.id
      assert NodeSessions.get(session.id) == nil
      assert NodeSessions.events(session.id) == []
    end
  end

  describe "records the hub can't use" do
    setup :started_session

    # hub-ingest-raises-on-malformed-record
    test "are stored without crashing the ingest", %{session: session} do
      assert :ok = NodeSessions.ingest(session.id, "box", 0, record("input", %{"id" => nil}))
      assert :ok = NodeSessions.ingest(session.id, "box", 1, record("input", %{"id" => 7}))

      assert :ok =
               NodeSessions.ingest(
                 session.id,
                 "box",
                 2,
                 state_record("idle", %{"answer" => %{"x" => 1}, "failure" => %{"message" => 3}})
               )

      assert :ok = NodeSessions.ingest(session.id, "box", 3, [1, 2])
      assert NodeSessions.get(session.id).next_offset == 4
      assert %{status: "idle", last_answer: nil, last_failure: nil} = NodeSessions.get(session.id)
    end
  end
end
