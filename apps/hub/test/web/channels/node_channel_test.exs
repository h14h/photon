defmodule PhotonWeb.NodeChannelTest do
  use Photon.DataCase, async: false

  import Phoenix.ChannelTest

  # Records are ingested through the durable store.
  @moduletag :durable

  alias Photon.{Nodes, NodeSessions}

  @endpoint PhotonWeb.Endpoint

  defp token_info(token), do: %{x_headers: [{"x-photon-token", token}]}

  defp join(node) do
    {:ok, socket} =
      connect(PhotonWeb.NodeSocket, %{}, connect_info: token_info(Photon.NodeAuth.token()))

    subscribe_and_join(socket, "node:" <> node, %{"hostname" => node, "version" => "0.1.0"})
  end

  test "rejects nodes without the token" do
    assert connect(PhotonWeb.NodeSocket, %{}, connect_info: token_info("nope")) == :error
    assert connect(PhotonWeb.NodeSocket, %{}, connect_info: %{x_headers: []}) == :error
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
end
