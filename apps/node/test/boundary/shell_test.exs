defmodule PhotonNode.Ops.ShellTest do
  @moduledoc """
  Regression tests for the shell operation, with the test process as its
  owner (`PhotonNode.TestOwner`): it gets the snapshots and answers the
  checkpoints.
  """

  use PhotonNode.NodeCase, async: false

  import PhotonNode.TestOwner,
    only: [
      owner: 0,
      owner: 1,
      crashing_owner: 0,
      await_status: 1,
      await_status: 2,
      await_pgid: 0
    ]

  alias PhotonNode.Executor.Request
  alias PhotonNode.Ops
  alias PhotonNode.Ops.Env

  # A shell operation as the executor builds it from the hub's `op.start`,
  # running in `directory` (the workspace when nil) with its files under
  # the node's ops directory.
  defp shell(command, %{ops_dir: ops_dir, workspace: workspace}, directory \\ nil) do
    start = %{
      "id" => PhotonCore.ID.new("op_"),
      "kind" => "shell",
      "args" => %{"command" => command, "directory" => directory, "max_output_length" => 10_000}
    }

    {:ok, op} =
      Request.operation(start, %{shell: Env.shell(), ops_dir: ops_dir, workspace: workspace})

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

  # Step 2 (ops:2): a project's folder on a machine is made on first use,
  # so a thread's first command doesn't fail with "start process: enoent".
  test "a missing working directory is created and the command runs in it",
       %{workspace: workspace} = context do
    project = Path.join(workspace, "proj")
    refute File.exists?(project)

    {:ok, _pid} = Ops.add(shell("pwd", context, "proj"), owner())

    assert %{"state" => %{"result" => %{"out" => out, "exit_code" => 0}}} =
             await_status("completed")

    assert String.trim(out) == project
    assert File.dir?(project)

    # A second operation there finds it.
    {:ok, _pid} = Ops.add(shell("echo again", context, "proj"), owner())

    assert %{"state" => %{"result" => %{"out" => "again\n", "exit_code" => 0}}} =
             await_status("completed")
  end

  test "a working directory blocked by a file fails the operation before the command runs",
       %{workspace: workspace} = context do
    File.mkdir_p!(workspace)
    blocked = Path.join(workspace, "proj")
    File.write!(blocked, "")
    marker = Path.join(workspace, "ran")

    {:ok, pid} = Ops.add(shell("touch #{marker}", context, "proj/sub"), owner())
    ref = Process.monitor(pid)

    assert %{"state" => %{"terminal_error" => error}} = await_status("failed")

    assert error ==
             "couldn't create the working directory #{blocked}/sub: not a directory. " <>
               "The command didn't run."

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    refute File.exists?(marker)
  end

  # Coordinator F3: the command started before its "process" checkpoint was
  # stored, so a coordinator that was down could later start it again.
  test "a command doesn't start until its owner has stored the checkpoint",
       %{workspace: workspace} = context do
    marker = Path.join(workspace, "ran")
    op = shell("touch #{marker}", context)
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

  # Registry.lookup/2 still returns a process that has just exited until
  # the registry handles its exit. Ops.add/2 sent such a process :resend,
  # and its owner, monitoring it, got :noproc for an operation whose
  # command never ran.
  test "an operation whose old process has just exited is started again", context do
    marker = Path.join(context.workspace, "ran")
    op = shell("touch #{marker}", context)
    nobody = spawn(fn -> :ok end)
    ref = Process.monitor(nobody)
    assert_receive {:DOWN, ^ref, :process, ^nobody, _}

    partition = Module.safe_concat(PhotonNode.OpRegistry, "PIDPartition0")
    :sys.suspend(partition)
    on_exit(fn -> if Process.whereis(partition), do: :sys.resume(partition) end)

    # A process for the operation that stops without starting the command,
    # since its owner is gone. With the registry held back, its entry
    # outlives it.
    {:ok, old} = Ops.add(op, owner(nobody))
    ref = Process.monitor(old)
    assert_receive {:DOWN, ^ref, :process, ^old, :normal}, 5_000
    assert [{^old, _}] = Registry.lookup(PhotonNode.OpRegistry, op["id"])

    {:ok, new} = Ops.add(op, owner())
    assert new != old
    await_status("completed")
    :sys.resume(partition)

    assert File.exists?(marker)
  end

  # Coordinator F8: a cancel that arrived before the wrapper's "pid" line
  # didn't kill the command, so the stop never finished.
  test "a cancel that arrives before the command's PID is known still kills it", context do
    pattern = "sleep 61.#{System.unique_integer([:positive])}"
    on_exit(fn -> kill_all(pattern) end)
    op = shell(pattern, context)

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
  test "a reattached command that exits leaving background children finishes", context do
    pattern = "sleep 62.#{System.unique_integer([:positive])}"
    on_exit(fn -> kill_all(pattern) end)

    op = shell("true", context)
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
  test "a command started just before a crash is found through its pid file", context do
    pattern = "sleep 63.#{System.unique_integer([:positive])}"
    on_exit(fn -> kill_all(pattern) end)

    op = shell("true", context)
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
  test "a shell stays responsive while a killed group takes its time to exit", context do
    pattern = "sleep 64.#{System.unique_integer([:positive])}"
    on_exit(fn -> kill_all(pattern) end)
    op = shell("trap '' TERM; #{pattern}", context)

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
  test "a command whose start the owner couldn't record fails without running",
       %{workspace: workspace} = context do
    marker = Path.join(workspace, "ran")
    op = shell("touch #{marker}", context)

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
  test "a command killed when its shell is shut down is reported as stopped, not completed",
       context do
    pattern = "sleep 65.#{System.unique_integer([:positive])}"
    on_exit(fn -> kill_all(pattern) end)
    op = shell(pattern, context)
    dir = Path.join(op["state"]["base_directory"], op["id"])

    {:ok, pid} = Ops.add(op, owner())
    running = await_pgid()

    :ok = DynamicSupervisor.terminate_child(PhotonNode.OpSupervisor, pid)
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

  # Node rule 10 after an abrupt crash: a shell that had reattached to its
  # command (no port; it polls the group) left the command running when it
  # was shut down, so a node stopped on purpose didn't stop it.
  test "a reattached command is killed and reported as stopped when its shell is shut down",
       context do
    pattern = "sleep 66.#{System.unique_integer([:positive])}"
    on_exit(fn -> kill_all(pattern) end)

    op = shell("true", context)
    dir = Path.join(op["state"]["base_directory"], op["id"])
    File.mkdir_p!(dir)
    reattached = recovered(op, dir, start_group(dir, pattern))

    {:ok, pid} = Ops.add(reattached, owner())
    # Once it has handled its start, it has reattached to the running group.
    _ = :sys.get_state(pid)

    :ok = DynamicSupervisor.terminate_child(PhotonNode.OpSupervisor, pid)
    assert gone?(pattern)
    assert File.exists?(Path.join(dir, "stopped"))

    {:ok, _pid} = Ops.add(reattached, owner())

    assert %{"state" => %{"terminal_error" => error}} = await_status("failed")

    assert error ==
             "photon-node stopped while the command was running, so the command was killed."
  end

  # E1 in specs/tla/Executor.md: the executor (or the node) died before it
  # stored the canceled snapshot of a command a cancel had killed, and the
  # resumed operation found the wrapper's exit 143 and reported the command
  # completed.
  test "a command killed by a cancel is resumed as canceled, not completed", context do
    pattern = "sleep 67.#{System.unique_integer([:positive])}"
    on_exit(fn -> kill_all(pattern) end)
    op = shell(pattern, context)
    dir = Path.join(op["state"]["base_directory"], op["id"])

    {:ok, pid} = Ops.add(op, owner())
    ref = Process.monitor(pid)
    running = await_pgid()
    send(pid, :cancel)

    # The canceled snapshot never reached the journal, which still holds
    # the running one.
    await_status("canceled")
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert gone?(pattern)
    assert File.exists?(Path.join(dir, "canceled"))
    assert File.read!(Path.join(dir, "exit")) == "143\n"

    {:ok, _pid} = Ops.add(running, owner())

    assert %{"state" => %{"terminal_error" => "shell operation canceled"}} =
             await_status("canceled")
  end

  # The same after an abrupt crash: a shell that reattached to its command
  # (no port) and was canceled.
  test "a reattached command killed by a cancel is resumed as canceled", context do
    pattern = "sleep 68.#{System.unique_integer([:positive])}"
    on_exit(fn -> kill_all(pattern) end)

    op = shell("true", context)
    dir = Path.join(op["state"]["base_directory"], op["id"])
    File.mkdir_p!(dir)
    reattached = recovered(op, dir, start_group(dir, pattern))

    {:ok, pid} = Ops.add(reattached, owner())
    _ = :sys.get_state(pid)
    send(pid, :cancel)

    await_status("canceled")
    assert gone?(pattern)
    assert File.exists?(Path.join(dir, "canceled"))
    # What a wrapper records for a command killed by SIGTERM.
    File.write!(Path.join(dir, "exit"), "143\n")

    {:ok, _pid} = Ops.add(reattached, owner())
    await_status("canceled")
  end

  # K2 in specs/tla/Executor.md: a shell resumed after an abrupt crash that
  # crashed before it reattached (here, in its first report) killed
  # nothing, so its command ran on after the operation failed.
  test "a resumed shell that crashes before it reattaches kills its command", context do
    pattern = "sleep 69.#{System.unique_integer([:positive])}"
    on_exit(fn -> kill_all(pattern) end)

    op = shell("true", context)
    dir = Path.join(op["state"]["base_directory"], op["id"])
    File.mkdir_p!(dir)
    pgid = start_group(dir, pattern)
    File.write!(Path.join(dir, "pid"), "#{pgid}\n")

    {:ok, pid} = Ops.add(recovered(op, dir, 0), crashing_owner())
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, {%RuntimeError{}, _stack}}, 10_000

    assert gone?(pattern)
    assert File.exists?(Path.join(dir, "stopped"))
  end

  # A command that exited on its own isn't reported as stopped by a shell
  # that crashes before it reads the exit file: the kill is only for what
  # the command left in its group.
  test "a resumed shell that crashes after its command exited leaves no stopped marker",
       context do
    pattern = "sleep 70.#{System.unique_integer([:positive])}"
    on_exit(fn -> kill_all(pattern) end)

    op = shell("true", context)
    dir = Path.join(op["state"]["base_directory"], op["id"])
    File.mkdir_p!(dir)
    pgid = start_group(dir, pattern)
    File.write!(Path.join(dir, "pid"), "#{pgid}\n")
    # The command's exit, as the wrapper records it; the group still holds
    # a background child it left.
    File.write!(Path.join(dir, "exit"), "0\n")

    {:ok, pid} = Ops.add(recovered(op, dir, 0), crashing_owner())
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, {%RuntimeError{}, _stack}}, 10_000

    assert gone?(pattern)
    refute File.exists?(Path.join(dir, "stopped"))
  end

  test "a fresh start clears a canceled marker left by an earlier one", context do
    op = shell("echo hi", context)
    dir = Path.join(op["state"]["base_directory"], op["id"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "canceled"), "")

    {:ok, _pid} = Ops.add(op, owner())
    await_status("completed")
    refute File.exists?(Path.join(dir, "canceled"))
  end

  # The executor died after storing the "process" checkpoint and before
  # answering, so the shell stopped without spawning, and the resumed
  # operation reported "outcome unknown" for a command that never ran.
  test "a command whose stored start was never confirmed runs once when resumed",
       %{workspace: workspace} = context do
    lines = Path.join(workspace, "lines")
    op = shell("echo ran >> #{lines}", context)
    dir = Path.join(op["state"]["base_directory"], op["id"])
    test = self()

    # An owner that stores the checkpoint (hands it to the test) and dies
    # before it answers.
    owner_pid =
      spawn(fn ->
        receive do
          {:"$gen_call", _from, {:checkpoint, stored}} -> send(test, {:stored, stored})
        end
      end)

    {:ok, pid} = Ops.add(op, owner(owner_pid))
    ref = Process.monitor(pid)
    assert_receive {:stored, %{"state" => %{"phase" => "process"}} = stored}, 10_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000
    refute File.exists?(lines)
    assert File.exists?(Path.join(dir, "unstarted"))

    {:ok, _pid} = Ops.add(stored, owner())

    assert %{"state" => %{"result" => %{"exit_code" => 0}}} = await_status("completed")
    assert File.read!(lines) == "ran\n"
    refute File.exists?(Path.join(dir, "unstarted"))
  end

  # At most once: without the marker, a stored start with no process group
  # and no pid file may have spawned, so it is never run again.
  test "a stored start with no process group, pid file or marker fails as unknown",
       %{workspace: workspace} = context do
    lines = Path.join(workspace, "lines")
    op = shell("echo ran >> #{lines}", context)
    dir = Path.join(op["state"]["base_directory"], op["id"])

    {:ok, _pid} = Ops.add(recovered(op, dir, 0), owner())

    assert %{"state" => %{"terminal_error" => error}} = await_status("failed")
    assert error == "shell execution outcome is unknown because process start was not recorded"
    refute File.exists?(lines)
  end

  test "a fresh start clears a stopped marker left by an earlier one", context do
    op = shell("echo hi", context)
    dir = Path.join(op["state"]["base_directory"], op["id"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "stopped"), "")

    {:ok, _pid} = Ops.add(op, owner())

    assert %{"state" => %{"result" => %{"out" => "hi\n", "exit_code" => 0}}} =
             await_status("completed")

    refute File.exists?(Path.join(dir, "stopped"))
  end

  # What the hub's `shell` tool tells the model: background children die
  # with the command's group, nohup or not, and a job started in its own
  # group with `bash -c 'set -m; nohup ...'` keeps running.
  test "background children are killed when the command exits, unless in a group of their own",
       context do
    unique = System.unique_integer([:positive])
    child = "sleep 63.#{unique}"
    server = "sleep 64.#{unique}"
    on_exit(fn -> for p <- [child, server], do: kill_all(p) end)

    command =
      "nohup #{child} >/dev/null 2>&1 & bash -c 'set -m; nohup #{server} >/dev/null 2>&1 &'"

    op = shell(command, context)
    {:ok, _pid} = Ops.add(op, owner())

    assert %{"state" => %{"result" => %{"exit_code" => 0}}} = await_status("completed")
    assert gone?(child)
    refute gone?(server)
  end

  test "new output streams to the owner while the command runs",
       %{workspace: workspace} = context do
    go = Path.join(workspace, "go")

    op =
      shell("echo started; while [ ! -f #{go} ]; do sleep 0.05; done", context)

    op_id = op["id"]

    {:ok, _pid} = Ops.add(op, owner())
    await_pgid()

    assert_receive {:output, ^op_id, "out", "started\n"}, 5_000
    File.write!(go, "")
    await_status("completed")
  end
end
