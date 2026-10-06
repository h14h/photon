defmodule PhotonNode.ConnectionTest do
  @moduledoc """
  Calls the connection's callbacks directly, with a stand-in for Slipstream's
  connection process that answers pushes and forwards them to the test.

  The test process is registered as `PhotonNode.Connection` (see
  `PhotonNode.NodeCase`), so what the executor sends the hub link
  arrives here as `{:op_snapshot, op}` and `{:op_output, id, stream,
  text}`, and a test hands it to `handle_info/2` to see what is pushed.
  """

  use PhotonNode.NodeCase, async: false

  alias PhotonCore.Operation.Wire
  alias PhotonNode.{Connection, Executor}

  defp fake_channel do
    test = self()

    spawn_link(fn -> forward_pushes(test) end)
  end

  defp forward_pushes(test) do
    receive do
      {:"$gen_call", from, {:__slipstream_command__, command}} ->
        GenServer.reply(from, make_ref())
        send(test, {:pushed, command.event, command.payload})

      {:__slipstream_command__, %Slipstream.Commands.JoinTopic{} = command} ->
        send(test, {:joining, command.topic, command.payload})
    end

    forward_pushes(test)
  end

  defp joined_socket do
    %Slipstream.Socket{
      channel_pid: fake_channel(),
      socket_pid: self(),
      joins: %{"node:test" => %Slipstream.Socket.Join{topic: "node:test", status: :joined}}
    }
  end

  # Rule 75: the session protocol is gone, so its messages are unknown
  # events, ignored like any other.
  test "session messages and unknown events are ignored" do
    socket = joined_socket()

    for {event, payload} <- [
          {"input", %{"session_id" => "s1", "input" => %{"id" => "in_1"}}},
          {"stop", %{"session_id" => "s1"}},
          {"resync", %{"session_id" => "s1", "from" => 0}},
          {"teleport", %{}}
        ] do
      assert {:ok, ^socket} = Connection.handle_message("node:test", event, payload, socket)
    end

    refute_receive {:op_snapshot, _}
    refute_received {:pushed, _, _}
  end

  describe "operations" do
    defp new_id, do: PhotonCore.ID.new("op_")

    test "op.start reaches the executor, and its snapshots are pushed while joined" do
      socket = joined_socket()
      id = new_id()
      args = %{"command" => "echo hi", "directory" => nil, "max_output_length" => 10_000}
      {"op.start", payload} = Wire.start(id, "shell", args, false)

      assert {:ok, ^socket} = Connection.handle_message("node:test", "op.start", payload, socket)

      assert_receive {:op_snapshot, %{"id" => ^id, "status" => "ready"}}, 10_000
      assert_receive {:op_snapshot, %{"id" => ^id, "status" => "completed"} = op}, 10_000
      assert op["state"]["result"]["out"] == "hi\n"

      {:noreply, ^socket} = Connection.handle_info({:op_snapshot, op}, socket)
      assert_receive {:pushed, "op.snapshot", %{"op" => ^op}}
    end

    test "op.cancel and op.ack reach the executor" do
      socket = joined_socket()
      id = new_id()
      {"op.cancel", cancel} = Wire.cancel(id)

      assert {:ok, ^socket} = Connection.handle_message("node:test", "op.cancel", cancel, socket)
      assert_receive {:op_snapshot, %{"id" => ^id, "status" => "canceled"}}
      assert [%{"id" => ^id}] = Executor.snapshots()

      {"op.ack", ack} = Wire.ack(id)
      assert {:ok, ^socket} = Connection.handle_message("node:test", "op.ack", ack, socket)
      assert Executor.snapshots() == []
    end

    test "after a join, every journaled snapshot is pushed" do
      [a, b] = Enum.sort([new_id(), new_id()])
      :ok = Executor.cancel(a)
      :ok = Executor.cancel(b)

      {:ok, _socket} = Connection.handle_join("node:test", %{}, joined_socket())

      assert_receive {:pushed, "op.snapshot", %{"op" => %{"id" => ^a, "status" => "canceled"}}}
      assert_receive {:pushed, "op.snapshot", %{"op" => %{"id" => ^b, "status" => "canceled"}}}
    end

    test "snapshots and output go out only while joined" do
      id = new_id()
      op = PhotonCore.Operation.new(id, "shell", 1, %{}, 1_000)

      {:noreply, _} = Connection.handle_info({:op_output, id, "out", "hi"}, joined_socket())
      assert_receive {:pushed, "op.output", %{"id" => ^id, "stream" => "out", "text" => "hi"}}

      left = %{joined_socket() | joins: %{}}
      {:noreply, _} = Connection.handle_info({:op_snapshot, op}, left)
      {:noreply, _} = Connection.handle_info({:op_output, id, "err", "oops"}, left)
      refute_receive {:pushed, _, _}
    end

    test "operation messages that don't parse are ignored" do
      socket = joined_socket()
      start = %{"id" => "../x", "kind" => "shell", "args" => %{}, "known" => false}

      assert {:ok, ^socket} = Connection.handle_message("node:test", "op.start", start, socket)
      assert {:ok, ^socket} = Connection.handle_message("node:test", "op.cancel", %{}, socket)

      assert {:ok, ^socket} =
               Connection.handle_message("node:test", "op.ack", %{"id" => "t_x"}, socket)

      assert {:ok, ^socket} =
               Connection.handle_message("node:test", "op.retry", %{"id" => new_id()}, socket)

      refute_receive {:op_snapshot, _}
      assert Executor.snapshots() == []
      refute_received {:pushed, _, _}
    end

    test "the join lists the ops:1 capability, and only it" do
      socket = %Slipstream.Socket{
        channel_pid: fake_channel(),
        socket_pid: self(),
        metadata: %{joins: %{}}
      }

      {:ok, _socket} = Connection.handle_connect(socket)
      assert_receive {:joining, "node:test", %{"capabilities" => ["ops:1"]}}
    end
  end
end
