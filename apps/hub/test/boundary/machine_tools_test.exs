defmodule Photon.MachineToolsTest do
  @moduledoc """
  Blip's machine tools (`Photon.MachineTools`) in the durable harness. Most
  tests drive Blip's conversation with the scripted model
  (`on mm1: $ <command>`), and a fake node joins the real node channel
  through `Phoenix.ChannelTest`: what the hub pushes to the node arrives
  here as `assert_push`, and the test answers with `op.snapshot`. A few
  tests that need one step at a time call the tools' `execute/2` and
  `resume/2` directly, on a real tool task.

  The wait limits are the test config's: a check every 200 ms, and giving
  up after 500 ms offline. How snapshots become results, and when a call
  gives up, is covered by `test/core/machine_tools/`.
  """

  use Photon.DataCase, async: false

  import Phoenix.ChannelTest
  import Photon.Fixtures, only: [call: 2]

  alias Photon.{Assistant, Machines}
  alias Photon.Durable.{Submission, TaskRecord, ToolAPI, Tx}
  alias Photon.Machines.Op
  alias Photon.MachineTools.{ListMachines, Shell, Translate, ViewImage}
  alias PhotonCore.Message

  @endpoint PhotonWeb.Endpoint

  @moduletag :durable

  # Longer than a check (200 ms), so a re-push or a give-up has time to come.
  @wait 3_000

  setup do
    c = Assistant.conversation_id()
    Durable.subscribe(c)
    %{conversation: c}
  end

  ## Helpers

  # A node somewhere off the tailnet (the tests run no tailscale).
  defp token_info(token),
    do: %{x_headers: [{"x-photon-token", token}], peer_data: %{address: {10, 0, 0, 5}}}

  defp key(machine) do
    {:ok, key} = Photon.NodeKeys.issue(machine)
    key
  end

  # A node that speaks the op protocol (or the given capabilities) joins as `machine`.
  defp join_node(machine, key \\ nil, capabilities \\ ["ops:2"]) do
    {:ok, socket} =
      connect(PhotonWeb.NodeSocket, %{}, connect_info: token_info(key || key(machine)))

    {:ok, _reply, socket} =
      subscribe_and_join(socket, "node:" <> machine, %{
        "hostname" => machine,
        "platform" => "linux",
        "workspace" => "/home/me/photon",
        "version" => "0.2.0",
        "capabilities" => capabilities
      })

    socket
  end

  defp snapshot(id, status, state) do
    %{
      "op" => %{
        "id" => id,
        "type" => "shell",
        "version" => 1,
        "status" => status,
        "max_output_length" => 40_000,
        "state" => state
      }
    }
  end

  # A finished shell op as a node reports it: its input, where its output
  # files are, and the result.
  defp completed(id, command, out) do
    snapshot(id, "completed", %{
      "input" => %{"command" => command, "shell" => "/bin/sh", "directory" => "/home/me/photon"},
      "out_path" => "/data/ops/#{id}/out",
      "err_path" => "/data/ops/#{id}/err",
      "result" => %{"out" => out, "err" => "", "exit_code" => 0}
    })
  end

  defp row(id), do: Repo.get(Op, id)

  defp results(c), do: for(%{kind: "tool_result"} = e <- Durable.entries(c), do: e.data)

  defp await_result(c) do
    entry = await_entry(c, &(&1.kind == "tool_result"), @wait)
    entry.data
  end

  # A tool task for a `shell` call in a fresh conversation, waiting on a
  # signal that never fires, so the scheduler leaves it to the test. The
  # API works in `workdir`, as a thread's does in its project's folder.
  defp tool_api(args, workdir \\ nil) do
    conversation = Durable.create_conversation("test")

    task =
      Durable.commit(
        &Tx.create_task(&1, %{
          kind: "tool",
          conversation_id: conversation.id,
          phase: "run",
          input: %{"call" => call("shell", args)},
          waiting: %{"signal" => "never"}
        })
      )

    ToolAPI.new(task, workdir)
  end

  defp limits(limits) do
    previous = Application.get_env(:photon, Photon.MachineTools)
    Application.put_env(:photon, Photon.MachineTools, limits)
    on_exit(fn -> Application.put_env(:photon, Photon.MachineTools, previous) end)
  end

  ## A call on an online machine

  describe "shell on an online machine" do
    test "parks, gets its result from the node's snapshot, and the node gets op.ack", %{
      conversation: c
    } do
      socket = join_node("mm1")
      {:ok, s} = Assistant.send("on mm1: $ echo hello")

      assert_push "op.start",
                  %{
                    "id" => id,
                    "kind" => "shell",
                    "known" => false,
                    "args" => %{"command" => "echo hello", "directory" => nil}
                  },
                  @wait

      assert %Op{status: "open", pushed: true} = row(id)

      push(socket, "op.snapshot", completed(id, "echo hello", "hello\n"))
      assert_push "op.ack", %{"id" => ^id}, @wait

      assert %{status: "done"} = await_settled(c, s.id, @wait)
      assert [%{"status" => "ok", "name" => "shell", "details" => details} = result] = results(c)
      assert Message.text_of(result["message"]) == "hello\n"

      assert %{
               "machine" => "mm1",
               "op_id" => ^id,
               "command" => "echo hello",
               "full_output" => "Full output: /data/ops/" <> _
             } = details

      assert List.last(texts(c, "assistant")) == "hello\n"

      # The claim closed the row and dropped its copy of the result.
      assert %Op{status: "closed", result: nil} = row(id)
    end

    test "view_image passes the image on", %{conversation: c} do
      socket = join_node("mm1")
      {:ok, s} = Assistant.send("on mm1: look at shot.png")

      assert_push "op.start",
                  %{"id" => id, "kind" => "view_image", "args" => %{"path" => "shot.png"}},
                  @wait

      image = %{
        "mime" => "image/png",
        "content" => "iVBORw0KGgo=",
        "width" => 1,
        "height" => 1,
        "path" => "/home/me/photon/shot.png"
      }

      push(socket, "op.snapshot", %{
        "op" => %{
          "id" => id,
          "type" => "view_image",
          "version" => 1,
          "status" => "completed",
          "max_output_length" => nil,
          "state" => %{"path" => "/home/me/photon/shot.png", "result" => image}
        }
      })

      assert %{status: "done"} = await_settled(c, s.id, @wait)
      assert [result] = results(c)
      assert [%{"mime" => "image/png"}] = Message.images(result["message"])
      assert List.last(texts(c, "assistant")) =~ "Here it is."
    end

    test "each recheck pushes the op again with known from the row, so a dropped op.start is recovered",
         %{conversation: c} do
      socket = join_node("mm1")
      {:ok, s} = Assistant.send("on mm1: $ echo once")

      # The node drops the first op.start; the next check pushes it again.
      assert_push "op.start", %{"id" => id, "known" => false}, @wait
      assert_push "op.start", %{"id" => ^id, "known" => false}, @wait

      push(socket, "op.snapshot", snapshot(id, "awaiting", %{}))
      assert_push "op.start", %{"id" => ^id, "known" => true}, @wait

      push(socket, "op.snapshot", completed(id, "echo once", "once\n"))
      assert_push "op.ack", %{"id" => ^id}, @wait
      assert %{status: "done"} = await_settled(c, s.id, @wait)
      assert [result] = results(c)
      assert Message.text_of(result["message"]) == "once\n"
    end

    test "a hub restart while parked asks for the same op", %{conversation: c} do
      socket = join_node("mm1")
      {:ok, s} = Assistant.send("on mm1: $ echo again")
      assert_push "op.start", %{"id" => id}, @wait

      stop_supervised!(Photon.Durable.Scheduler)
      stop_supervised!(Photon.Durable.Store)
      start_supervised!(Photon.Durable.Store)
      start_supervised!(Photon.Durable.Scheduler)

      assert_push "op.start", %{"id" => ^id}, @wait
      push(socket, "op.snapshot", completed(id, "echo again", "again\n"))
      assert %{status: "done"} = await_settled(c, s.id, @wait)
      assert [_one] = results(c)
    end
  end

  ## Reruns of execute

  describe "a rerun of execute" do
    test "finds the same op: one row, and the same op pushed again" do
      :ok = Photon.MachineOps.connect("mm1")
      api = tool_api(%{"machine" => "mm1", "command" => "echo hi"})
      args = %{"machine" => "mm1", "command" => "echo hi"}

      assert {:wait, %{"signal" => "op:" <> id}, %{"op_id" => id, "offline_since" => nil}} =
               Shell.execute(args, api)

      assert {:wait, %{"signal" => "op:" <> ^id}, %{"op_id" => ^id}} = Shell.execute(args, api)
      assert_received {:push_op, ^id}
      assert_received {:push_op, ^id}
      assert Repo.aggregate(Op, :count) == 1
    end

    test "parks without checking the machine, even if it is now unknown" do
      _key = key("mm1")
      args = %{"machine" => "mm1", "command" => "echo hi"}
      api = tool_api(args)
      assert {:wait, _waiting, %{"op_id" => id}} = Shell.execute(args, api)

      :ok = Photon.NodeKeys.revoke("mm1")
      assert Machines.status("mm1") == :unknown
      assert {:wait, %{"signal" => "op:" <> ^id}, _state} = Shell.execute(args, api)

      # A fresh call on the unknown machine fails, and lists what the hub knows.
      assert {:commit, fun} = Shell.execute(args, tool_api(args))
      assert {:error, "There is no machine called \"mm1\"" <> _} = Durable.commit(fun)
    end

    test "a machine with an older photon-node fails at once" do
      :ok = Photon.MachineOps.connect("old", [])
      args = %{"machine" => "old", "command" => "echo hi"}
      assert {:commit, fun} = Shell.execute(args, tool_api(args))
      assert {:error, "old runs an older photon-node" <> _} = Durable.commit(fun)
    end

    test "a bad argument fails before any op" do
      args = %{"machine" => "mm1", "command" => "echo \0"}

      assert {:error, "shell argument \"command\" contains a NUL byte" <> _} =
               Shell.execute(args, tool_api(args))

      assert Repo.aggregate(Op, :count) == 0
    end
  end

  describe "a working directory" do
    test "goes into the op's directory, in its row and in op.start" do
      _socket = join_node("mm1")
      args = %{"machine" => "mm1", "command" => "ls"}

      assert {:wait, _waiting, %{"op_id" => id}} =
               Shell.execute(args, tool_api(args, "garden"))

      assert %Op{args: %{"command" => "ls", "directory" => "garden"}} = row(id)
      assert_push "op.start", %{"id" => ^id, "args" => %{"directory" => "garden"}}
    end

    test "view_image takes it too, for a relative path" do
      :ok = Photon.MachineOps.connect("mm1")
      args = %{"machine" => "mm1", "path" => "shots/a.png"}

      assert {:wait, _waiting, %{"op_id" => id}} =
               ViewImage.execute(args, tool_api(args, "garden"))

      assert %Op{args: %{"path" => "shots/a.png", "directory" => "garden"}} = row(id)
    end

    test "is none for Blip's calls, which run in the workspace" do
      :ok = Photon.MachineOps.connect("mm1")
      args = %{"machine" => "mm1", "command" => "ls"}
      assert {:wait, _waiting, %{"op_id" => id}} = Shell.execute(args, tool_api(args))
      assert %Op{args: %{"directory" => nil}} = row(id)
    end
  end

  ## Offline machines

  describe "an offline machine" do
    test "gives up past the limit: the command didn't run, and the next join cancels it", %{
      conversation: c
    } do
      key = key("mm1")
      {:ok, s} = Assistant.send("on mm1: $ echo hi")

      assert %{"status" => "error", "message" => message} = await_result(c)

      assert Message.text_of(message) ==
               "Error: mm1 has been offline for 500 milliseconds, so the command didn't run. " <>
                 "It won't run when mm1 comes back."

      await_settled(c, s.id, @wait)
      assert [%Op{id: id, cancel: true, status: "open", pushed: false}] = Repo.all(Op)

      _socket = join_node("mm1", key)
      assert_push "op.cancel", %{"id" => ^id}, @wait
      refute_push "op.start", _
    end

    test "the machine comes back between the offline check and the give-up: op.start went out, so the message hedges and the node gets op.cancel" do
      key = key("mm1")
      args = %{"machine" => "mm1", "command" => "echo hi"}
      api = tool_api(args)

      assert {:wait, _waiting, %{"offline_since" => since} = state} = Shell.execute(args, api)
      assert is_integer(since)

      # The call reads the machine as offline past the limit...
      limits(check_ms: 200, offline_limit_ms: 0)
      assert {:commit, give_up} = Shell.resume(state, api)

      # ...then the node joins and gets the op...
      _socket = join_node("mm1", key)
      assert_push "op.start", %{"id" => id}, @wait

      # ...and then the give-up commits.
      assert {:error, message} = Durable.commit(give_up)
      assert message =~ "mm1 was offline for 0 milliseconds and has just come back"
      assert_push "op.cancel", %{"id" => ^id}, @wait
      assert %Op{cancel: true, pushed: true} = row(id)
    end

    # Step 2, section 3.4 point 7: an ops:1 node wouldn't create a
    # project's working directory, so it gets no op.start, and the call
    # ends rather than waiting out the offline limit on a connected machine.
    test "a call parked while its machine is offline ends with the outdated message when the machine comes back with an older photon-node" do
      key = key("mm1")
      args = %{"machine" => "mm1", "command" => "echo hi"}
      api = tool_api(args)
      assert {:wait, _waiting, %{"op_id" => id} = state} = Shell.execute(args, api)

      old = join_node("mm1", key, ["ops:1"])
      _ = :sys.get_state(old.channel_pid)
      refute_push "op.start", _
      assert %Op{status: "open", pushed: false} = row(id)

      assert {:commit, fun} = Shell.resume(state, api)
      assert {:error, message} = Durable.commit(fun)
      assert message == Translate.outdated_machine("mm1")
      assert %Op{status: "open", cancel: true, pushed: false} = row(id)
      # An ops:1 node understands op.cancel (it journals it, for an op it
      # never had), so the cancel still goes out.
      assert_push "op.cancel", %{"id" => ^id}, @wait

      # Reinstalled with a current build, it is told to cancel the op,
      # never to start it.
      Process.unlink(old.channel_pid)
      _socket = join_node("mm1", key)
      assert_push "op.cancel", %{"id" => ^id}, @wait
      refute_push "op.start", _
    end

    test "local parks while it is offline, on a hub that runs its own node" do
      Application.put_env(:photon, :local_node, true)
      on_exit(fn -> Application.put_env(:photon, :local_node, false) end)

      args = %{"machine" => "local", "command" => "uname -a"}

      assert {:wait, %{"signal" => "op:" <> _id}, %{"offline_since" => since}} =
               Shell.execute(args, tool_api(args))

      assert is_integer(since)
    end
  end

  ## Calls that end another way

  describe "a call that ends without its result" do
    @tag :capture_log
    test "a raise after the op exists ends with an error, and cancels the op" do
      socket = join_node("mm1")
      conversation = Durable.create_conversation("test")
      c = conversation.id
      Durable.subscribe(c)

      {:ok, _s} = Durable.submit(c, "shell then raise on mm1")
      assert_push "op.start", %{"id" => id}, @wait

      assert %{"status" => "error", "message" => message} = await_result(c)
      assert Message.text_of(message) == "Error: boom after the op started"
      assert_push "op.cancel", %{"id" => ^id}, @wait
      assert %Op{cancel: true, status: "open"} = row(id)
      _ = :sys.get_state(socket.channel_pid)
    end

    test "Stop cancels the op, and the node gets op.cancel", %{conversation: c} do
      _socket = join_node("mm1")
      {:ok, s} = Assistant.send("on mm1: $ sleep 30")
      assert_push "op.start", %{"id" => id}, @wait

      Assistant.stop()
      assert_push "op.cancel", %{"id" => ^id}, @wait
      assert %{status: "unanswered"} = await_settled(c, s.id, @wait)
      assert [%{"status" => "aborted"}] = results(c)
      assert %Op{cancel: true, status: "open"} = row(id)
    end

    test "Stop after the result came in, before the call claimed it, closes the row without it",
         %{conversation: c} do
      socket = join_node("mm1")
      {:ok, s} = Assistant.send("on mm1: $ echo hi")
      assert_push "op.start", %{"id" => id}, @wait

      # The scheduler is held, so the result's signal can't wake the call
      # before the stop is applied.
      stop_supervised!(Photon.Durable.Scheduler)
      push(socket, "op.snapshot", completed(id, "echo hi", "hi\n"))
      assert_push "op.ack", %{"id" => ^id}, @wait
      assert {:finished, _snapshot} = Machines.op_state(id)

      Assistant.stop()
      start_supervised!(Photon.Durable.Scheduler)

      assert %{status: "unanswered"} = await_settled(c, s.id, @wait)
      assert [%{"status" => "aborted"}] = results(c)
      assert %Op{status: "closed", result: nil} = row(id)
    end

    test "Stop withdraws the user's queued messages but keeps background input", %{
      conversation: c
    } do
      _socket = join_node("mm1")
      {:ok, first} = Assistant.send("on mm1: $ sleep 30")
      assert_push "op.start", _payload, @wait

      {:ok, mine} = Assistant.send("and also this")
      {:ok, routine} = Durable.submit(c, "[Scheduled] hello", source: %{"kind" => "routine"})
      assert {mine.status, routine.status} == {"queued", "queued"}

      Assistant.stop()
      await_settled(c, first.id, @wait)
      assert Repo.get(Submission, mine.id).status == "withdrawn"

      # The scheduled prompt runs once the stopped run has ended.
      assert %{status: "done"} = await_settled(c, routine.id, @wait)
    end
  end

  ## list_machines

  describe "list_machines" do
    test "lists local, the connected machines, an outdated one and the offline ones" do
      Application.put_env(:photon, :local_node, true)
      on_exit(fn -> Application.put_env(:photon, :local_node, false) end)

      _key = key("nas")
      _socket = join_node("mm1")
      :ok = Photon.MachineOps.connect("old", [])

      {:ok, text} = ListMachines.execute(%{}, tool_api(%{}))

      assert text ==
               Enum.join(
                 [
                   "- local (this hub's own computer): offline",
                   "- mm1: online, linux, hostname mm1, workspace /home/me/photon, photon-node 0.2.0",
                   "- old: online, but it runs an older photon-node that can't take commands; " <>
                     "it needs reinstalling from the Nodes page",
                   "- nas: offline"
                 ],
                 "\n"
               )
    end

    test "with a working directory, says what it is and names its path on each machine that takes commands" do
      _key = key("nas")
      _socket = join_node("mm1")
      :ok = Photon.MachineOps.connect("old", [])

      {:ok, text} = ListMachines.execute(%{}, tool_api(%{}, "garden"))

      assert text ==
               Enum.join(
                 [
                   "Your working directory on each machine is <workspace>/garden, made on first use.",
                   "",
                   "- mm1: online, linux, hostname mm1, workspace /home/me/photon, photon-node 0.2.0, " <>
                     "working directory /home/me/photon/garden",
                   "- old: online, but it runs an older photon-node that can't take commands; " <>
                     "it needs reinstalling from the Nodes page",
                   "- nas: offline"
                 ],
                 "\n"
               )
    end

    test "says when there are none" do
      assert {:ok, "No machines yet." <> _} = ListMachines.execute(%{}, tool_api(%{}))
      assert {:ok, "No machines yet." <> _} = ListMachines.execute(%{}, tool_api(%{}, "garden"))
    end
  end

  test "a stopped task's op isn't recorded" do
    :ok = Photon.MachineOps.connect("mm1")
    args = %{"machine" => "mm1", "command" => "echo hi"}
    api = tool_api(args)
    Durable.commit(&Tx.update_task(&1, Repo.get(TaskRecord, api.task.id), abort_requested: true))

    assert {:commit, fun} = Shell.execute(args, api)
    assert {:error, "The call was stopped before it reached mm1."} = Durable.commit(fun)
    assert Repo.aggregate(Op, :count) == 0
    refute_received {:push_op, _}
  end
end
