defmodule PhotonWeb.NodeChannelTest do
  use ExUnit.Case

  import Phoenix.ChannelTest

  alias Photon.{Nodes, Sessions}

  @endpoint PhotonWeb.Endpoint

  setup do
    File.rm_rf!(Photon.Paths.data_dir())
    :ets.delete_all_objects(Sessions.counts_table())
    :ok
  end

  defp token_info(token), do: %{x_headers: [{"x-photon-token", token}]}

  test "rejects nodes without the token" do
    assert connect(PhotonWeb.NodeSocket, %{}, connect_info: token_info("nope")) == :error
    assert connect(PhotonWeb.NodeSocket, %{}, connect_info: %{x_headers: []}) == :error
  end

  test "joins with a sync map, ingests events and tracks runs" do
    %{"id" => id} = Sessions.create("t", "box")
    Sessions.ingest(id, "box", 0, %{"seen" => true})
    Phoenix.PubSub.subscribe(Photon.PubSub, Nodes.topic())

    {:ok, socket} =
      connect(PhotonWeb.NodeSocket, %{}, connect_info: token_info(Photon.NodeAuth.token()))

    {:ok, reply, socket} =
      subscribe_and_join(socket, "node:box", %{"hostname" => "box", "runner" => "/r"})

    assert reply == %{"sync" => %{id => 1}}
    assert_receive :nodes_changed
    assert %{"hostname" => "box", "runner" => "/r"} = Nodes.get("box")

    push(socket, "event", %{"session_id" => id, "offset" => 3, "event" => %{}})
    assert_push "resync", %{"session_id" => ^id, "from" => 1}

    ref = push(socket, "event", %{"session_id" => id, "offset" => 1, "event" => %{"n" => 1}})
    refute_reply ref, _
    push(socket, "run_started", %{"session_id" => id})
    assert_receive :nodes_changed
    :sys.get_state(socket.channel_pid)
    assert MapSet.member?(Nodes.running_ids(), id)
    assert length(Sessions.events(id)) == 2

    :ok = Nodes.start_run("box", id, "hi", %{"provider" => "mock"})
    assert_push "start_run", %{"session_id" => ^id, "prompt" => "hi"}

    push(socket, "run_finished", %{"session_id" => id, "status" => 0})
    :sys.get_state(socket.channel_pid)
    refute MapSet.member?(Nodes.running_ids(), id)

    Process.unlink(socket.channel_pid)
    close(socket)
    assert_receive :nodes_changed
    Process.sleep(20)
    assert Nodes.get("box") == nil
    assert Nodes.start_run("box", id, "hi", %{}) == {:error, :offline}
  end

  test "a reconnecting node replaces its stale connection" do
    {:ok, s1} =
      connect(PhotonWeb.NodeSocket, %{}, connect_info: token_info(Photon.NodeAuth.token()))

    {:ok, _, s1} = subscribe_and_join(s1, "node:dup", %{})
    Process.unlink(s1.channel_pid)
    ref = Process.monitor(s1.channel_pid)

    {:ok, s2} =
      connect(PhotonWeb.NodeSocket, %{}, connect_info: token_info(Photon.NodeAuth.token()))

    {:ok, _, s2} = subscribe_and_join(s2, "node:dup", %{})
    assert_receive {:DOWN, ^ref, _, _, _}
    assert [{pid, _}] = Registry.lookup(Photon.NodeRegistry, "dup")
    assert pid == s2.channel_pid
  end
end
