defmodule PhotonWeb.NodeChannelTest do
  use Photon.DataCase, async: false

  import Phoenix.ChannelTest

  # Records are ingested through the durable store.
  @moduletag :durable

  import Photon.MachineOps, only: [live_task: 0, new_op: 2, snapshot: 2, snapshot: 3]

  alias Photon.{Durable, Machines, Nodes, NodeSessions}

  @endpoint PhotonWeb.Endpoint

  # A node somewhere off the tailnet (the tests run no tailscale).
  defp token_info(token),
    do: %{x_headers: [{"x-photon-token", token}], peer_data: %{address: {10, 0, 0, 5}}}

  defp join(node) do
    {:ok, key} = Photon.NodeKeys.issue(node)
    {:ok, socket} = connect(PhotonWeb.NodeSocket, %{}, connect_info: token_info(key))
    subscribe_and_join(socket, "node:" <> node, %{"hostname" => node, "version" => "0.1.0"})
  end

  @tag capture_log: true
  test "rejects nodes without a key of their own" do
    assert connect(PhotonWeb.NodeSocket, %{}, connect_info: token_info("nope")) == :error
    assert connect(PhotonWeb.NodeSocket, %{}, connect_info: %{x_headers: []}) == :error

    local = Photon.NodeKeys.local_token()
    assert connect(PhotonWeb.NodeSocket, %{}, connect_info: token_info(local)) == :error
  end

  test "a key joins as its own node only" do
    {:ok, key} = Photon.NodeKeys.issue("box")
    {:ok, socket} = connect(PhotonWeb.NodeSocket, %{}, connect_info: token_info(key))

    assert {:error, %{"reason" => "this key belongs to box, not other"}} =
             subscribe_and_join(socket, "node:other", %{})

    refute Nodes.online?("other")
  end

  @tag capture_log: true
  test "a connection whose key was replaced is closed, and can't join again" do
    {:ok, key} = Photon.NodeKeys.issue("box")
    {:ok, socket} = connect(PhotonWeb.NodeSocket, %{}, connect_info: token_info(key))
    {:ok, _reply, joined} = subscribe_and_join(socket, "node:box", %{})
    assert socket.id == "node_socket:box:#{socket.assigns.generation}"
    topic = socket.id
    PhotonWeb.Endpoint.subscribe(topic)

    Process.unlink(joined.channel_pid)
    ref = Process.monitor(joined.channel_pid)
    {:ok, _new_key} = Photon.NodeKeys.issue("box")

    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic}
    assert_receive {:DOWN, ^ref, :process, _pid, {:shutdown, :key_replaced}}
    refute Nodes.online?("box")

    assert {:error, %{"reason" => "this key has been replaced"}} =
             subscribe_and_join(socket, "node:box", %{})
  end

  test "a connection made before a removal can't join after the node is installed again" do
    {:ok, key} = Photon.NodeKeys.issue("box")
    {:ok, idle} = connect(PhotonWeb.NodeSocket, %{}, connect_info: token_info(key))

    :ok = Photon.NodeKeys.revoke("box")
    {:ok, _new_key} = Photon.NodeKeys.issue("box")

    assert {:error, %{"reason" => "this key has been replaced"}} =
             subscribe_and_join(idle, "node:box", %{})
  end

  test "a node can't touch another node's sessions" do
    {:ok, theirs, input} = NodeSessions.start("other", "hello")
    {:ok, _reply, socket} = join("box")
    NodeSessions.subscribe(theirs.id)

    push(socket, "live", %{"session_id" => theirs.id, "data" => %{"text" => "spoofed"}})

    push(socket, "input_rejected", %{
      "session_id" => theirs.id,
      "input_id" => input.id,
      "reason" => "nope"
    })

    # The channel handles messages in order, so the reply-less push above has
    # been dealt with once this one is.
    _ = :sys.get_state(socket.channel_pid)
    refute_received {:node_live, _, _}
    assert NodeSessions.input(input.id).state == "queued"
  end

  @tag capture_log: true
  test "a hub that vouches through its tailnet refuses keys from anywhere it can't name" do
    Application.put_env(:photon, :auth_mode, :tailscale)
    on_exit(fn -> Application.delete_env(:photon, :auth_mode) end)
    {:ok, key} = Photon.NodeKeys.issue("box")

    assert connect(PhotonWeb.NodeSocket, %{}, connect_info: token_info(key)) == :error
  end

  test "joins with a sync map, resends queued input, and ingests records" do
    {:ok, session, input} = NodeSessions.start("box", "hello")
    Phoenix.PubSub.subscribe(Photon.PubSub, Nodes.topic())

    {:ok, reply, socket} = join("box")
    assert reply == %{"sync" => %{session.id => 0}}
    assert_receive :nodes_changed
    assert %{"hostname" => "box"} = Nodes.get("box")

    input_id = input.id

    assert_push "input", %{
      "session_id" => _,
      "input" => %{"id" => ^input_id},
      "config" => %{"model" => _}
    }

    push(socket, "event", %{"session_id" => session.id, "offset" => 3, "event" => %{}})
    assert_push "resync", %{"from" => 0}

    push(socket, "event", %{
      "session_id" => session.id,
      "offset" => 0,
      "event" => %{"kind" => "session"}
    })

    push(socket, "event", %{
      "session_id" => session.id,
      "offset" => 1,
      "event" => %{"kind" => "input", "data" => %{"id" => input.id}}
    })

    _ = :sys.get_state(socket.channel_pid)
    assert length(NodeSessions.events(session.id)) == 2
    assert NodeSessions.input(input.id).state == "accepted"

    {:ok, stop} = NodeSessions.stop(session.id)
    stop_id = stop.id
    assert_push "input", %{"input" => %{"id" => ^stop_id, "kind" => "control"}}

    Process.unlink(socket.channel_pid)
    close(socket)
    assert_receive :nodes_changed
    _ = :sys.get_state(Photon.NodeRegistry |> Process.whereis() || self())
  end

  test "a reconnecting node replaces its stale connection" do
    {:ok, _, s1} = join("dup")
    Process.unlink(s1.channel_pid)
    ref = Process.monitor(s1.channel_pid)

    {:ok, _, s2} = join("dup")
    assert_receive {:DOWN, ^ref, _, _, _}
    assert [{pid, _}] = Registry.lookup(Photon.NodeRegistry, "dup")
    assert pid == s2.channel_pid
  end

  # NS-7: a send racing the resend at join pushed the same input twice on
  # one connection; the node could refuse the first and accept the second.
  test "an input is pushed to a connected node at most once" do
    {:ok, session, input} = NodeSessions.start("box2", "hello")
    {:ok, _reply, _socket} = join("box2")

    input_id = input.id
    assert_push "input", %{"input" => %{"id" => ^input_id}}

    Nodes.command("box2", "input", %{"session_id" => session.id, "input" => input.input})
    Nodes.command("box2", "stop", %{"session_id" => session.id})
    assert_push "stop", _
    refute_push "input", _
  end

  describe "operations" do
    test "the join pushes open ops; a result is recorded, then acked" do
      task = live_task()
      %{id: id} = op = new_op(task, "box")
      :ok = Machines.start(op)

      {:ok, _reply, socket} = join("box")
      assert_push "op.start", %{"id" => ^id, "kind" => "shell", "known" => false}

      push(socket, "op.snapshot", snapshot(id, "awaiting"))
      push(socket, "op.snapshot", snapshot(id, "completed", %{"result" => %{"out" => "hi"}}))
      assert_push "op.ack", %{"id" => ^id}
      assert {:finished, %{"status" => "completed"}} = Machines.op_state(id)
      assert Durable.signal_payload(Machines.signal_key(id)) != nil
    end

    test "an op started while the node is connected is pushed by its channel, with known" do
      {:ok, _reply, socket} = join("box")
      %{id: id} = op = new_op(live_task(), "box")
      :ok = Machines.start(op)
      assert_push "op.start", %{"id" => ^id, "known" => false}

      push(socket, "op.snapshot", snapshot(id, "awaiting"))
      :ok = Machines.repush(id)
      assert_push "op.start", %{"id" => ^id, "known" => true}

      :ok = Durable.commit(&Machines.cancel_tx(&1, id))
      assert_push "op.cancel", %{"id" => ^id}
      :ok = Machines.repush(id)
      _ = :sys.get_state(socket.channel_pid)
      refute_push "op.start", _
    end

    test "output goes to the tool call's conversation" do
      task = live_task()
      %{id: id, call_id: call_id} = op = new_op(task, "box")
      :ok = Machines.start(op)
      c = task.conversation_id
      Durable.subscribe(c)

      {:ok, _reply, socket} = join("box")
      push(socket, "op.output", %{"id" => id, "stream" => "out", "text" => "one"})
      push(socket, "op.output", %{"id" => id, "stream" => "err", "text" => "two"})

      assert_receive {:live, ^c,
                      %{"type" => "tool_output", "call_id" => ^call_id, "text" => "one"}}

      assert_receive {:live, ^c, %{"stream" => "err", "text" => "two"}}
    end

    @tag capture_log: true
    test "a node can't finish another node's op, or stream into its call" do
      task = live_task()
      %{id: id} = op = new_op(task, "other")
      :ok = Machines.start(op)
      Durable.subscribe(task.conversation_id)

      {:ok, _reply, socket} = join("box")
      push(socket, "op.snapshot", snapshot(id, "completed"))
      push(socket, "op.output", %{"id" => id, "stream" => "out", "text" => "spoofed"})

      _ = :sys.get_state(socket.channel_pid)
      refute_push "op.ack", _
      refute_received {:live, _, _}
      assert Machines.op_state(id) == {:open, false}
    end

    @tag capture_log: true
    test "an op.start built anywhere but the channel is dropped" do
      {:ok, _reply, socket} = join("box")
      %{id: id} = new_op(live_task(), "box")

      Nodes.command("box", "op.start", %{
        "id" => id,
        "kind" => "shell",
        "args" => %{},
        "known" => false
      })

      _ = :sys.get_state(socket.channel_pid)
      refute_push "op.start", _
    end
  end
end
