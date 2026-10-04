defmodule PhotonNode.ConnectionTest do
  @moduledoc """
  Calls the connection's callbacks directly, with a stand-in for Slipstream's
  connection process that answers pushes and forwards them to the test.
  """

  use PhotonNode.HarnessCase, async: false

  alias PhotonNode.Connection
  alias PhotonNode.Harness.Store

  defp fake_channel do
    test = self()

    spawn_link(fn -> forward_pushes(test) end)
  end

  defp forward_pushes(test) do
    receive do
      {:"$gen_call", from, {:__slipstream_command__, command}} ->
        GenServer.reply(from, make_ref())
        send(test, {:pushed, command.event, command.payload})
    end

    forward_pushes(test)
  end

  defp joined_socket do
    %Slipstream.Socket{
      channel_pid: fake_channel(),
      socket_pid: self(),
      joins: %{"node:test" => %Slipstream.Socket.Join{topic: "node:test", status: :joined}},
      assigns: %{sent: %{}}
    }
  end

  # Swaps in a Store whose second read of a log first appends `line` to it,
  # the way the session's coordinator can append between two reads. The
  # real module is put back afterwards.
  defp with_append_on_second_read(line, fun) do
    {module, binary, file} = :code.get_object_code(Store)
    Process.put(:store_shim_append, line)
    Code.put_compiler_option(:ignore_module_conflict, true)

    Code.compile_string("""
    defmodule PhotonNode.Harness.Store do
      def path(id), do: Path.join(PhotonNode.Config.sessions_dir(PhotonNode.config()), id <> ".jsonl")

      def read(id) do
        reads = Process.get(:store_shim_reads, 0) + 1
        Process.put(:store_shim_reads, reads)
        if reads == 2, do: File.write!(path(id), Process.get(:store_shim_append), [:append])
        path(id) |> File.read!() |> String.split("\\n", trim: true) |> Enum.map(&Jason.decode!/1)
      end

      def read_from(id, offset),
        do: read(id) |> Enum.with_index() |> Enum.drop(offset) |> Enum.map(fn {r, i} -> {i, r} end)

      def count(id), do: length(read(id))
    end
    """)

    try do
      fun.()
    after
      :code.purge(module)
      {:module, ^module} = :code.load_binary(module, file, binary)
      :code.purge(module)
      Code.put_compiler_option(:ignore_module_conflict, false)
    end
  end

  # NS-1: replay/3 read the log twice when nothing was new; a record
  # appended between the reads was neither replayed nor, when its own
  # notification came, pushed (it looked like a duplicate).
  test "a record appended while the join replays is pushed when it is announced" do
    {store, _header} = Store.create("c1", %{})
    {store, _input} = Store.append(store, "input", message("hi"))
    Store.close(store)
    idle = %{"seq" => 2, "at" => "now", "kind" => "state", "data" => %{"state" => "idle"}}

    socket =
      with_append_on_second_read(Jason.encode!(idle) <> "\n", fn ->
        {:ok, socket} =
          Connection.handle_join("node:test", %{"sync" => %{"c1" => 2}}, joined_socket())

        socket
      end)

    {:noreply, socket} = Connection.handle_info({:event, "c1", 2, idle}, socket)
    assert_receive {:pushed, "event", %{"session_id" => "c1", "offset" => 2}}
    assert socket.assigns.sent == %{"c1" => 3}
  end

  test "a replay pushes what the hub is missing and nothing it has" do
    {store, _header} = Store.create("c2", %{})
    {store, _input} = Store.append(store, "input", message("hi"))
    Store.close(store)

    {:ok, socket} =
      Connection.handle_join("node:test", %{"sync" => %{"c2" => 1}}, joined_socket())

    assert_receive {:pushed, "event", %{"session_id" => "c2", "offset" => 1}}
    refute_receive {:pushed, "event", %{"offset" => 0}}
    assert socket.assigns.sent == %{"c2" => 2}
  end

  describe "commands from the hub" do
    test "an input is delivered, and one the node can't take is rejected with the reason" do
      socket = joined_socket()
      input = message("help")

      assert {:ok, ^socket} =
               Connection.handle_message(
                 "node:test",
                 "input",
                 %{"session_id" => "c3", "input" => input},
                 socket
               )

      assert Store.exists?("c3")
      refute_received {:pushed, "input_rejected", _}

      stop = %{"id" => "x", "kind" => "control", "payload" => %{"mode" => "hard"}}

      {:ok, _} =
        Connection.handle_message(
          "node:test",
          "input",
          %{"session_id" => "c4", "input" => stop},
          socket
        )

      assert_receive {:pushed, "input_rejected",
                      %{
                        "session_id" => "c4",
                        "input_id" => "x",
                        "reason" => "session c4 doesn't exist"
                      }}
    end

    test "a resync replays from the offset asked for; delete forgets the session" do
      write_log("c5", %{}, [{"input", message("hi")}, {"state", %{"state" => "idle"}}])
      socket = joined_socket()

      {:ok, socket} =
        Connection.handle_message(
          "node:test",
          "resync",
          %{"session_id" => "c5", "from" => 1},
          socket
        )

      assert_receive {:pushed, "event", %{"session_id" => "c5", "offset" => 1}}
      assert_receive {:pushed, "event", %{"session_id" => "c5", "offset" => 2}}
      assert socket.assigns.sent == %{"c5" => 3}

      {:ok, socket} =
        Connection.handle_message("node:test", "delete_session", %{"session_id" => "c5"}, socket)

      assert socket.assigns.sent == %{}
      refute Store.exists?("c5")
    end

    test "events with an invalid session ID, and unknown events, are ignored" do
      socket = joined_socket()
      long = String.duplicate("a", 65)

      assert {:ok, ^socket} =
               Connection.handle_message("node:test", "stop", %{"session_id" => long}, socket)

      assert {:ok, ^socket} = Connection.handle_message("node:test", "teleport", %{}, socket)

      assert {:ok, ^socket} =
               Connection.handle_message(
                 "node:test",
                 "resync",
                 %{"session_id" => "../x", "from" => 0},
                 socket
               )

      refute_received {:pushed, _, _}
    end
  end

  describe "forwarding" do
    test "live data goes out only while joined" do
      {:noreply, _} = Connection.handle_info({:live, "c6", %{"type" => "text"}}, joined_socket())
      assert_receive {:pushed, "live", %{"session_id" => "c6", "data" => %{"type" => "text"}}}

      left = %{joined_socket() | joins: %{}}
      {:noreply, _} = Connection.handle_info({:live, "c6", %{}}, left)
      {:noreply, _} = Connection.handle_info({:event, "c6", 0, %{}}, left)
      refute_receive {:pushed, _, _}
    end

    test "a record below the watermark is a duplicate; one above it is a gap that replays" do
      write_log("c7", %{}, [{"input", message("hi")}, {"state", %{"state" => "idle"}}])
      socket = %{joined_socket() | assigns: %{sent: %{"c7" => 1}}}

      {:noreply, socket} = Connection.handle_info({:event, "c7", 0, %{}}, socket)
      refute_received {:pushed, _, _}

      {:noreply, socket} = Connection.handle_info({:event, "c7", 2, %{}}, socket)
      assert_receive {:pushed, "event", %{"session_id" => "c7", "offset" => 1}}
      assert_receive {:pushed, "event", %{"session_id" => "c7", "offset" => 2}}
      assert socket.assigns.sent == %{"c7" => 3}
    end
  end
end
