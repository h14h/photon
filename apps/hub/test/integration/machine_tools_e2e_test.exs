defmodule Photon.MachineToolsE2ETest do
  @moduledoc """
  Blip's machine tools against a real node: the hub's durable harness,
  the real node channel and a real `PhotonNode` (executor, journal and
  shell processes) talking over a websocket, as the hub's own `local`
  node does in development (`docs/plans/step-1-machine-tools.md`, section
  6.1).

  The test endpoint has `server: false`, so each test starts a Bandit
  listener for `PhotonWeb.Endpoint` on a free loopback port and points the
  node at it. Bandit serves the endpoint's node socket in the test env, so
  the plan's fallback (a bridge process joining through
  `Phoenix.ChannelTest`) isn't needed. The node dials in with the built-in
  node's key (`Photon.NodeKeys.local_token/0`), which loopback may use, as
  machine `local`.

  Blip is driven with the scripted model (`config :photon, :mock_model`):
  `on local: $ <command>` calls `shell`, and `on local: look at <path>`
  calls `view_image`. The offline limit is raised to a minute, so a node
  that is restarted on purpose comes back long before a call gives up.
  """

  use Photon.DataCase, async: false

  import Photon.Eventually

  alias Photon.{Assistant, Machines}
  alias Photon.Machines.Op
  alias PhotonCore.Message
  alias PhotonNode.Executor.Journal

  @moduletag :durable
  @moduletag :tmp_dir

  # Commands here run for a second or two; a node restart takes a few more.
  @wait 15_000

  # A 1x1 PNG.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
       )

  setup %{tmp_dir: dir} do
    put_env(:local_node, true)
    put_env(Photon.MachineTools, check_ms: 200, offline_limit_ms: 60_000)

    bandit =
      start_supervised!(
        {Bandit,
         plug: PhotonWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    node = [
      server: "ws://127.0.0.1:#{port}/node/websocket",
      token: Photon.NodeKeys.local_token(),
      node_id: "local",
      data_dir: Path.join(dir, "node")
    ]

    c = Assistant.conversation_id()
    Durable.subscribe(c)
    %{conversation: c, node: node, ops_dir: Path.join([dir, "node", "ops"])}
  end

  ## Helpers

  defp put_env(key, value) do
    previous = Application.get_env(:photon, key)
    Application.put_env(:photon, key, value)
    on_exit(fn -> Application.put_env(:photon, key, previous) end)
  end

  # Starts the node and waits until the hub has it online.
  defp start_node(opts) do
    start_supervised!({PhotonNode, opts})
    assert eventually(fn -> Machines.status("local") == :online end, @wait)
  end

  # Commands run here, and relative paths resolve against it.
  defp workspace(node), do: Path.join(node[:data_dir], "workspace")

  defp results(c), do: for(%{kind: "tool_result"} = e <- Durable.entries(c), do: e.data)

  defp reply(c), do: List.last(texts(c, "assistant"))

  # The op of the call in flight: the test runs one call at a time.
  defp the_op, do: eventually(fn -> Repo.one(Op) end, @wait)

  # Waits until the op's command has spawned: its journal entry is
  # `awaiting` with the command's process group (0 until it has one).
  defp await_running(ops_dir, id) do
    assert eventually(
             fn ->
               match?(
                 {:ok, %{"op" => %{"status" => "awaiting", "state" => %{"pgid" => pgid}}}}
                 when is_integer(pgid) and pgid > 1,
                 Journal.read(ops_dir, id)
               )
             end,
             @wait
           )
  end

  # Once the hub has acked a result, the node forgets the op's entry.
  defp await_forgotten(ops_dir, id),
    do: assert(eventually(fn -> Journal.read(ops_dir, id) == {:ok, nil} end, @wait))

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  ## Tests

  test "shell runs a command on the node, and Blip relays its output", %{
    conversation: c,
    node: node,
    ops_dir: ops_dir
  } do
    start_node(node)
    {:ok, s} = Assistant.send("on local: $ echo hello")

    assert %{status: "done"} = await_settled(c, s.id, @wait)
    assert reply(c) =~ "hello"
    assert [%{"status" => "ok", "details" => %{"machine" => "local", "op_id" => id}}] = results(c)

    assert %Op{status: "closed", confirmed: true, result: nil} = Repo.get(Op, id)
    await_forgotten(ops_dir, id)
  end

  test "view_image returns the image", %{conversation: c, node: node} do
    start_node(node)
    File.write!(Path.join(workspace(node), "dot.png"), @png)

    {:ok, s} = Assistant.send("on local: look at dot.png")

    assert %{status: "done"} = await_settled(c, s.id, @wait)
    assert [%{"status" => "ok", "message" => message}] = results(c)
    assert [%{"mime" => "image/png"}] = Message.images(message)
    assert Message.text_of(message) =~ "1x1 image/png"
    assert reply(c) =~ "Here it is."
  end

  test "killing the node's executor leaves the command running, and its result arrives once",
       %{conversation: c, node: node, ops_dir: ops_dir} do
    start_node(node)
    runs = Path.join(workspace(node), "runs")
    {:ok, s} = Assistant.send("on local: $ echo run >> runs; sleep 1; echo done")

    %Op{id: id} = the_op()
    await_running(ops_dir, id)

    # The supervisor restarts the executor and the connection after it.
    kill(Process.whereis(PhotonNode.Executor))

    assert %{status: "done"} = await_settled(c, s.id, @wait)
    assert [%{"status" => "ok", "message" => message}] = results(c)
    assert Message.text_of(message) == "done\n"
    assert reply(c) =~ "done"
    assert File.read!(runs) == "run\n"
  end

  test "stopping the node's channel on the hub makes the node rejoin, and the result arrives once",
       %{conversation: c, node: node, ops_dir: ops_dir} do
    start_node(node)
    runs = Path.join(workspace(node), "runs")
    {:ok, s} = Assistant.send("on local: $ echo run >> runs; sleep 1; echo done")

    %Op{id: id} = the_op()
    await_running(ops_dir, id)

    [{channel, _info}] = Registry.lookup(Photon.NodeRegistry, "local")
    kill(channel)

    assert %{status: "done"} = await_settled(c, s.id, @wait)
    assert [%{"status" => "ok", "message" => message}] = results(c)
    assert Message.text_of(message) == "done\n"
    assert File.read!(runs) == "run\n"
    await_forgotten(ops_dir, id)
  end

  test "a node stopped on purpose kills the command, and says so once it is back", %{
    conversation: c,
    node: node,
    ops_dir: ops_dir
  } do
    start_node(node)
    {:ok, s} = Assistant.send("on local: $ sleep 30")

    %Op{id: id} = the_op()
    await_running(ops_dir, id)

    stop_supervised!(PhotonNode)
    start_node(node)

    assert %{status: "done"} = await_settled(c, s.id, @wait)
    assert [%{"status" => "ok", "message" => message}] = results(c)

    assert "Error: photon-node stopped while the command was running, so the command was killed." <>
             _status = Message.text_of(message)

    assert reply(c) =~ "That didn't work: photon-node stopped"
    await_forgotten(ops_dir, id)
  end

  test "Stop cancels a running command on the node", %{
    conversation: c,
    node: node,
    ops_dir: ops_dir
  } do
    start_node(node)
    {:ok, s} = Assistant.send("on local: $ sleep 30")

    %Op{id: id} = the_op()
    await_running(ops_dir, id)

    Assistant.stop()

    assert %{status: "unanswered"} = await_settled(c, s.id, @wait)
    assert [%{"status" => "aborted"}] = results(c)

    # The node kills the command and reports it canceled; the hub closes the
    # row and acks, and the node forgets the op.
    assert eventually(fn -> match?(%Op{status: "closed"}, Repo.get(Op, id)) end, @wait)
    await_forgotten(ops_dir, id)
  end

  test "an op stopped while the node was away is canceled before it starts when the node joins",
       %{conversation: c, node: node, ops_dir: ops_dir} do
    runs = Path.join(workspace(node), "runs")
    {:ok, s} = Assistant.send("on local: $ echo run >> runs")

    # `local` is known but offline: the call parks with its row unpushed.
    %Op{id: id, pushed: false} = the_op()
    Assistant.stop()
    assert %{status: "unanswered"} = await_settled(c, s.id, @wait)

    # The join sends op.cancel; the node answers "canceled before it
    # started", the hub closes the row and acks, and nothing ran.
    start_node(node)

    assert eventually(
             fn -> match?(%Op{status: "closed", confirmed: true}, Repo.get(Op, id)) end,
             @wait
           )

    await_forgotten(ops_dir, id)
    refute File.exists?(runs)
  end
end
