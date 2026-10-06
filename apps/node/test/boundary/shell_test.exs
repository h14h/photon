defmodule PhotonNode.Harness.ShellTest do
  @moduledoc """
  Regression tests for the shell operation, with the test process as its
  owner (`PhotonNode.TestOwner`): it gets the snapshots and answers the
  checkpoints.
  """

  use PhotonNode.HarnessCase, async: false

  import PhotonNode.TestOwner,
    only: [owner: 0, owner: 1, await_status: 1, await_status: 2, await_pgid: 0]

  alias PhotonNode.Harness.{Env, Ops, Store}
  alias PhotonNode.Harness.Tools.Bash

  # A shell operation as the Bash translator builds it for a session.
  defp translated_op(session_id, command, workspace) do
    File.mkdir_p!(workspace)

    env = %{
      workspace: workspace,
      shell: Env.shell(),
      operations_dir: Store.operations_dir(session_id),
      skills: []
    }

    call = %{
      "id" => "c1",
      "name" => "Bash",
      "arguments" => Jason.encode!(%{"command" => command})
    }

    {_status, [op]} = Bash.translate(call, env)
    op
  end

  defp op_pid(op_id) do
    case Registry.lookup(PhotonNode.OpRegistry, op_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp gone?(pattern) do
    {output, _status} = System.cmd("pgrep", ["-f", pattern])
    output == ""
  end

  defp kill_all(pattern), do: System.cmd("pkill", ["-KILL", "-f", pattern])

  # Coordinator F3: the command started before its "process" checkpoint was
  # stored, so a coordinator that was down could later start it again.
  test "a command doesn't start until its owner has stored the checkpoint", %{
    workspace: workspace
  } do
    marker = Path.join(workspace, "ran")
    op = translated_op("nobody_home", "touch #{marker}", workspace)
    nobody = spawn(fn -> :ok end)
    ref = Process.monitor(nobody)
    assert_receive {:DOWN, ^ref, :process, ^nobody, _}
    _ = Ops.add(op, owner(nobody))

    if pid = op_pid(op["id"]) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 10_000
    end

    refute File.exists?(marker)
  end

  # Coordinator F8: a cancel that arrived before the wrapper's "pid" line
  # didn't kill the command, so the stop never finished.
  test "a cancel that arrives before the command's PID is known still kills it", %{
    workspace: workspace
  } do
    pattern = "sleep 61.#{System.unique_integer([:positive])}"
    on_exit(fn -> kill_all(pattern) end)
    op = translated_op("fake8", pattern, workspace)

    {:ok, _pid} = Ops.add(op, owner())
    send(op_pid(op["id"]), :cancel)

    assert %{"state" => %{"terminal_error" => "shell operation canceled"}} =
             await_status("canceled")

    assert gone?(pattern)
  end

  # A process group whose leader waits for `go`, writes its exit file and
  # exits, leaving a background child (`child`) behind. Returns its PGID.
  defp start_group(dir, child) do
    go = Path.join(dir, "go")
    exit_file = Path.join(dir, "exit")

    script =
      "echo $$; exec >/dev/null 2>&1; #{child} & " <>
        "while [ ! -f #{go} ]; do sleep 0.05; done; echo 0 > #{exit_file}.tmp && mv #{exit_file}.tmp #{exit_file}"

    port =
      Port.open({:spawn_executable, System.find_executable("setsid")}, [
        :binary,
        {:line, 64},
        args: ["/bin/sh", "-c", script]
      ])

    assert_receive {^port, {:data, {:eol, leader}}}, 5_000
    String.to_integer(leader)
  end

  # The operation as recovery finds it after a node restart: files ready,
  # the "process" checkpoint stored, with or without its PGID.
  defp recovered(op, dir, pgid) do
    File.mkdir_p!(dir)
    for f <- ~w(out err), do: File.write!(Path.join(dir, f), "")

    %{
      op
      | "status" => "awaiting",
        "state" =>
          Map.merge(op["state"], %{
            "phase" => "process",
            "pgid" => pgid,
            "out_path" => Path.join(dir, "out"),
            "err_path" => Path.join(dir, "err")
          })
    }
  end

  # Coordinator F11: a shell reattached after a restart waited for background
  # children of a command that had already exited and written its exit file.
  test "a reattached command that exits leaving background children finishes", %{
    workspace: workspace
  } do
    pattern = "sleep 62.#{System.unique_integer([:positive])}"
    on_exit(fn -> kill_all(pattern) end)

    op = translated_op("fake11", "true", workspace)
    dir = Path.join(op["state"]["base_directory"], op["id"])
    File.mkdir_p!(dir)
    pgid = start_group(dir, pattern)

    {:ok, _pid} = Ops.add(recovered(op, dir, pgid), owner())
    # Once it has handled its start, it has reattached to the running group.
    _ = :sys.get_state(op_pid(op["id"]))
    File.write!(Path.join(dir, "go"), "")

    assert %{"state" => %{"result" => %{"exit_code" => 0}}} = await_status("completed")
    assert gone?(pattern)
  end

  # K1 (known upstream gap): a node that crashed after the "process"
  # checkpoint but before the PGID one recovered the operation as "outcome
  # unknown" and left its command running unwatched.
  test "a command started just before a crash is found through its pid file", %{
    workspace: workspace
  } do
    pattern = "sleep 63.#{System.unique_integer([:positive])}"
    on_exit(fn -> kill_all(pattern) end)

    op = translated_op("fakek1", "true", workspace)
    dir = Path.join(op["state"]["base_directory"], op["id"])
    File.mkdir_p!(dir)
    pgid = start_group(dir, pattern)
    File.write!(Path.join(dir, "pid"), "#{pgid}\n")

    {:ok, _pid} = Ops.add(recovered(op, dir, 0), owner())
    _ = :sys.get_state(op_pid(op["id"]))
    File.write!(Path.join(dir, "go"), "")

    assert %{"state" => %{"result" => %{"exit_code" => 0}}} = await_status("completed")
    assert gone?(pattern)
  end

  # Rule 96: killing a group doesn't sleep in the shell's process, so it
  # still answers while the group takes its time; a message that comes
  # meanwhile is handled once the group is gone, in order.
  test "a shell stays responsive while a killed group takes its time to exit", %{
    workspace: workspace
  } do
    pattern = "sleep 64.#{System.unique_integer([:positive])}"
    on_exit(fn -> kill_all(pattern) end)
    op = translated_op("fakekill", "trap '' TERM; #{pattern}", workspace)

    {:ok, pid} = Ops.add(op, owner())
    await_pgid()
    send(pid, :cancel)

    # The group ignores SIGTERM, so it lives until SIGKILL five seconds on.
    assert %{killing: %{}} = :sys.get_state(pid, 1_000)
    send(pid, :resend)

    assert_receive {:report, %{"status" => "awaiting"}}, 10_000

    assert %{"state" => %{"terminal_error" => "shell operation canceled"}} =
             await_status("canceled")

    assert gone?(pattern)
  end

  # Node rule 8: a checkpoint the owner couldn't store never runs anything.
  test "a command whose start the owner couldn't record fails without running", %{
    workspace: workspace
  } do
    marker = Path.join(workspace, "ran")
    op = translated_op("unrecorded", "touch #{marker}", workspace)

    {:ok, pid} = Ops.add(op, owner())
    ref = Process.monitor(pid)

    assert %{"state" => %{"terminal_error" => error}} =
             await_status("failed", {:error, "write op.json: no space left on device"})

    assert error ==
             "couldn't record the command's start, so it didn't run: " <>
               "write op.json: no space left on device"

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    refute File.exists?(marker)
  end

  # Node rule 10: a command killed because photon-node stopped was resumed
  # as completed with exit 143, since the wrapper outside the killed group
  # recorded that status.
  test "a command killed when its shell is shut down is reported as stopped, not completed", %{
    workspace: workspace
  } do
    pattern = "sleep 65.#{System.unique_integer([:positive])}"
    on_exit(fn -> kill_all(pattern) end)
    op = translated_op("stopped", pattern, workspace)
    dir = Path.join(op["state"]["base_directory"], op["id"])

    {:ok, pid} = Ops.add(op, owner())
    running = await_pgid()

    :ok = DynamicSupervisor.terminate_child(PhotonNode.Harness.OpSupervisor, pid)
    assert gone?(pattern)
    assert File.exists?(Path.join(dir, "stopped"))

    # What the wrapper records once its command is killed by SIGTERM; written
    # here too, since the wrapper may not have got to it yet.
    File.write!(Path.join(dir, "exit"), "143\n")

    {:ok, _pid} = Ops.add(running, owner())

    assert %{"state" => %{"terminal_error" => error}} = await_status("failed")

    assert error ==
             "photon-node stopped while the command was running, so the command was killed. " <>
               "Its exit status was 143."
  end

  test "a fresh start clears a stopped marker left by an earlier one", %{workspace: workspace} do
    op = translated_op("restarted", "echo hi", workspace)
    dir = Path.join(op["state"]["base_directory"], op["id"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "stopped"), "")

    {:ok, _pid} = Ops.add(op, owner())

    assert %{"state" => %{"result" => %{"out" => "hi\n", "exit_code" => 0}}} =
             await_status("completed")

    refute File.exists?(Path.join(dir, "stopped"))
  end

  test "new output streams to the owner while the command runs", %{workspace: workspace} do
    go = Path.join(workspace, "go")

    op =
      translated_op("live", "echo started; while [ ! -f #{go} ]; do sleep 0.05; done", workspace)

    op_id = op["id"]

    {:ok, _pid} = Ops.add(op, owner())
    await_pgid()

    assert_receive {:output, ^op_id, "out", "started\n"}, 5_000
    File.write!(go, "")
    await_status("completed")
  end
end
