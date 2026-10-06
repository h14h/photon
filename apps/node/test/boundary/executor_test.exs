defmodule PhotonNode.ExecutorTest do
  @moduledoc """
  The executor through its API, run as a whole node with no hub
  connection in a temporary data directory. `PhotonNode.TestLink` stands
  in for the hub link: the test process gets every snapshot, with what the
  journal held when it was sent, and live output.

  Some tests journal operations before the node starts, to see what its
  start-up scan does with them, so each test starts the node itself.
  What `Executor.Request` and `Executor.Rules` decide is covered in
  `test/core/executor`.
  """

  use ExUnit.Case, async: false

  alias PhotonCore.Operation
  alias PhotonNode.Executor
  alias PhotonNode.Executor.{Journal, Request}
  alias PhotonNode.Ops.Env
  alias PhotonNode.TestLink

  @stopped "photon-node stopped while the command was running, so the command was killed."

  setup do
    dir =
      Path.join(System.tmp_dir!(), "photon-executor-test-#{System.unique_integer([:positive])}")

    ops_dir = Path.join(dir, "ops")
    workspace = Path.join(dir, "workspace")
    File.mkdir_p!(ops_dir)
    File.mkdir_p!(workspace)

    on_exit(fn ->
      TestLink.unhold()
      File.chmod(ops_dir, 0o700)
      File.rm_rf(dir)
    end)

    Process.register(self(), TestLink)
    {:ok, dir: dir, ops_dir: ops_dir, workspace: workspace}
  end

  defp start_node(dir) do
    opts = [token: "test", data_dir: dir, node_id: "test", connect: false, link: TestLink]
    start_supervised!({PhotonNode, opts})
    # Once this answers, the start-up scan has run.
    _ = :sys.get_state(Executor)
    :ok
  end

  defp new_id, do: PhotonCore.ID.new("op_")

  defp shell_start(id, command, known \\ false) do
    args = %{"command" => command, "directory" => nil, "max_output_length" => 10_000}
    %{"id" => id, "kind" => "shell", "args" => args, "known" => known}
  end

  # The next snapshot of `id` with `status`, skipping the others.
  defp await_snapshot(id, status, timeout \\ 10_000) do
    receive do
      {:snapshot, %{"id" => ^id, "status" => ^status} = op, journaled} -> {op, journaled}
      {:snapshot, %{"id" => ^id}, _journaled} -> await_snapshot(id, status, timeout)
    after
      timeout -> flunk("no #{status} snapshot of #{id}")
    end
  end

  # Every snapshot of `id` up to the first with `status`, each with what
  # the journal held when the link got it.
  defp collect(id, status) do
    receive do
      {:snapshot, %{"id" => ^id, "status" => ^status} = op, journaled} ->
        [{op, journaled}]

      {:snapshot, %{"id" => ^id} = op, journaled} ->
        [{op, journaled} | collect(id, status)]
    after
      10_000 -> flunk("no #{status} snapshot of #{id}")
    end
  end

  # The next snapshot of `id` that shows its command's process group.
  defp await_pgid(id) do
    receive do
      {:snapshot, %{"id" => ^id, "state" => %{"pgid" => pgid}} = op, _journaled}
      when is_integer(pgid) and pgid > 0 ->
        op

      {:snapshot, %{"id" => ^id}, _journaled} ->
        await_pgid(id)
    after
      10_000 -> flunk("no snapshot of #{id} with a process group")
    end
  end

  defp op_pid(id) do
    case Registry.lookup(PhotonNode.OpRegistry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp entry_file(ops_dir, id), do: Path.join(Journal.op_dir(ops_dir, id), "op.json")

  defp lines(path), do: path |> File.read!() |> String.split("\n", trim: true)

  # Lets a command gated on `go` (see `gated/2`) go on.
  defp go(workspace), do: File.write!(Path.join(workspace, "go"), "")

  # A command that runs `before`, waits until the test writes `go` in the
  # workspace, then runs `after_go`. Commands run in the workspace.
  defp gated(before, after_go),
    do: "#{before}; while [ ! -f go ]; do sleep 0.05; done; #{after_go}"

  defp kill_group(pgid), do: System.cmd("/bin/sh", ["-c", "kill -KILL -#{pgid} 2>/dev/null"])

  defp kill_executor do
    pid = Process.whereis(Executor)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    # The supervisor has restarted it once it answers, and the new
    # executor has scanned the journal once that one does.
    _ = :sys.get_state(PhotonNode)
    _ = :sys.get_state(Executor)
    :ok
  end

  ## Running

  test "a shell operation is journaled as ready, then reports its progress and result", %{
    dir: dir,
    ops_dir: ops_dir,
    workspace: workspace
  } do
    start_node(dir)
    id = new_id()

    :ok = Executor.start(shell_start(id, gated("echo started", "echo done >&2")))

    [{ready, _journaled} | _] = snapshots = collect(id, "awaiting")
    assert ready["status"] == "ready"
    assert ready["state"]["input"]["directory"] == workspace
    assert ready["state"]["base_directory"] == ops_dir

    assert_receive {:output, ^id, "out", "started\n"}, 5_000
    go(workspace)
    snapshots = snapshots ++ collect(id, "completed")
    {completed, _journaled} = List.last(snapshots)

    # Every snapshot was in the journal before the hub link got it.
    for {op, journaled} <- snapshots, do: assert(op == journaled)

    assert %{"out" => "started\n", "err" => "done\n", "exit_code" => 0} =
             completed["state"]["result"]

    assert {:ok, %{"op" => ^completed, "cancel" => false}} = Journal.read(ops_dir, id)
    assert Executor.snapshots() == [completed]
  end

  test "a repeated start sends the latest snapshot and never runs the command again", %{
    dir: dir,
    workspace: workspace
  } do
    start_node(dir)
    id = new_id()
    ran = Path.join(workspace, "ran")
    start = shell_start(id, gated("echo run >> ran", "true"))

    :ok = Executor.start(start)
    running = await_pgid(id)

    # While it runs, from the journal.
    :ok = Executor.start(start)
    assert {^running, _journaled} = await_snapshot(id, "awaiting")

    go(workspace)
    {completed, _journaled} = await_snapshot(id, "completed")

    # Once it has finished, whether or not the hub has seen it.
    :ok = Executor.start(start)
    assert {^completed, _journaled} = await_snapshot(id, "completed")
    :ok = Executor.start(%{start | "known" => true})
    assert {^completed, _journaled} = await_snapshot(id, "completed")

    assert lines(ran) == ["run"]
  end

  test "an operation the hub has seen but the node has no record of fails without running", %{
    dir: dir,
    ops_dir: ops_dir,
    workspace: workspace
  } do
    start_node(dir)
    id = new_id()

    :ok = Executor.start(shell_start(id, "touch ran", true))

    assert {failed, nil} = await_snapshot(id, "failed")

    assert failed["state"]["terminal_error"] ==
             "The machine has no record of this operation. It may or may not have run."

    refute File.exists?(entry_file(ops_dir, id))
    refute File.exists?(Path.join(workspace, "ran"))
  end

  test "an unsupported kind comes back as a failed snapshot", %{dir: dir, ops_dir: ops_dir} do
    start_node(dir)
    id = new_id()

    :ok = Executor.start(%{"id" => id, "kind" => "teleport", "args" => %{}, "known" => false})

    assert {%{"type" => "teleport", "state" => %{"terminal_error" => error}}, nil} =
             await_snapshot(id, "failed")

    assert error =~ ~s(kind "teleport")
    refute File.exists?(entry_file(ops_dir, id))
  end

  ## Cancels

  test "a cancel during a run ends the operation as canceled", %{dir: dir, ops_dir: ops_dir} do
    start_node(dir)
    id = new_id()

    :ok = Executor.start(shell_start(id, "sleep 30"))
    await_pgid(id)
    :ok = Executor.cancel(id)

    assert {%{"state" => %{"terminal_error" => "shell operation canceled"}} = canceled, canceled} =
             await_snapshot(id, "canceled")

    assert {:ok, %{"cancel" => true}} = Journal.read(ops_dir, id)
  end

  test "a cancel before the start is journaled, so a later start runs nothing", %{
    dir: dir,
    ops_dir: ops_dir,
    workspace: workspace
  } do
    start_node(dir)
    id = new_id()

    :ok = Executor.cancel(id)

    assert {%{"state" => %{"terminal_error" => "Canceled before it started."}} = canceled,
            canceled} = await_snapshot(id, "canceled")

    :ok = Executor.start(shell_start(id, "touch ran"))
    assert {^canceled, _journaled} = await_snapshot(id, "canceled")
    refute File.exists?(Path.join(workspace, "ran"))

    :ok = Executor.ack(id)
    refute File.exists?(entry_file(ops_dir, id))
  end

  test "a cancel of a finished operation changes nothing", %{dir: dir, ops_dir: ops_dir} do
    start_node(dir)
    id = new_id()

    :ok = Executor.start(shell_start(id, "true"))
    {completed, _journaled} = await_snapshot(id, "completed")
    :ok = Executor.cancel(id)

    assert {:ok, %{"op" => ^completed, "cancel" => false}} = Journal.read(ops_dir, id)
    refute_received {:snapshot, %{"id" => ^id}, _journaled}
  end

  # Node rule 4: the `process` checkpoint isn't confirmed when the journal
  # says canceled.
  test "a cancel journaled before the command's start means it never spawns", %{
    dir: dir,
    ops_dir: ops_dir,
    workspace: workspace
  } do
    id = new_id()
    {:ok, ready} = Request.operation(shell_start(id, "touch ran"), facts(dir))
    :ok = Journal.write(ops_dir, id, %{"op" => ready, "cancel" => true})

    start_node(dir)

    assert {%{"state" => %{"terminal_error" => "shell operation canceled"}}, _journaled} =
             await_snapshot(id, "canceled")

    refute File.exists?(Path.join(workspace, "ran"))
  end

  # Node rule 2: a cancel journaled while no process ran (here, before the
  # node stopped) is applied when the scan resumes the operation.
  test "the start-up scan cancels a resumed operation whose journal says canceled", %{
    dir: dir,
    ops_dir: ops_dir
  } do
    id = new_id()
    pattern = "sleep 71.#{System.unique_integer([:positive])}"
    {op, pgid} = journal_running(dir, ops_dir, id, pattern)
    on_exit(fn -> kill_group(pgid) end)
    :ok = Journal.write(ops_dir, id, %{"op" => running(op, pgid), "cancel" => true})

    start_node(dir)

    assert {_canceled, _journaled} = await_snapshot(id, "canceled")
    refute group_alive?(pgid)
  end

  ## Acks and the sweep

  test "an ack forgets the entry and keeps the output; the sweep removes old output", %{
    dir: dir,
    ops_dir: ops_dir
  } do
    day = 24 * 60 * 60
    now = System.os_time(:second)

    for {name, age} <- [{"op_old", 8 * day}, {"op_young", day}] do
      File.mkdir_p!(Journal.op_dir(ops_dir, name))
      File.write!(Path.join(Journal.op_dir(ops_dir, name), "out"), "old")
      File.touch!(Journal.op_dir(ops_dir, name), now - age)
    end

    start_node(dir)

    refute File.exists?(Journal.op_dir(ops_dir, "op_old"))
    assert File.exists?(Journal.op_dir(ops_dir, "op_young"))

    id = new_id()
    :ok = Executor.start(shell_start(id, "echo hi"))
    await_snapshot(id, "completed")

    :ok = Executor.ack(id)

    refute File.exists?(entry_file(ops_dir, id))
    assert File.read!(Path.join(Journal.op_dir(ops_dir, id), "out")) == "hi\n"
    assert File.exists?(Path.join(Journal.op_dir(ops_dir, id), "err"))
    assert Executor.snapshots() == []
  end

  test "an ack of an unfinished operation is ignored", %{dir: dir, ops_dir: ops_dir} do
    start_node(dir)
    id = new_id()

    :ok = Executor.start(shell_start(id, "sleep 30"))
    pgid = await_pgid(id)["state"]["pgid"]
    on_exit(fn -> kill_group(pgid) end)
    :ok = Executor.ack(id)

    assert File.exists?(entry_file(ops_dir, id))
  end

  ## Crashes

  # F9: a crashed operation process fails its operation.
  test "an operation process killed with :kill fails its operation", %{dir: dir} do
    start_node(dir)
    id = new_id()

    :ok = Executor.start(shell_start(id, "sleep 30"))
    pgid = await_pgid(id)["state"]["pgid"]
    on_exit(fn -> kill_group(pgid) end)
    Process.exit(op_pid(id), :kill)

    assert {%{"state" => %{"terminal_error" => "the operation process exited: killed"}} = failed,
            failed} = await_snapshot(id, "failed")
  end

  test "an operation process that exits cleanly before its result is restarted once", %{
    dir: dir,
    ops_dir: ops_dir
  } do
    id = new_id()
    pattern = "sleep 72.#{System.unique_integer([:positive])}"
    {op, pgid} = journal_running(dir, ops_dir, id, pattern)
    on_exit(fn -> kill_group(pgid) end)
    :ok = Journal.write(ops_dir, id, %{"op" => running(op, pgid), "cancel" => false})

    # The scan resumes it, reattached to the running group.
    start_node(dir)
    first = op_pid(id)
    _ = :sys.get_state(first)

    :ok = GenServer.stop(first, :shutdown)
    _ = :sys.get_state(Executor)
    second = op_pid(id)
    assert is_pid(second) and second != first
    refute_received {:snapshot, %{"id" => ^id}, _journaled}

    :ok = GenServer.stop(second, :shutdown)

    assert {%{"state" => %{"terminal_error" => "the operation process exited: shutdown"}},
            _journaled} = await_snapshot(id, "failed")
  end

  test "a killed executor leaves the command running, and the result arrives once", %{
    dir: dir,
    workspace: workspace
  } do
    start_node(dir)
    id = new_id()

    :ok = Executor.start(shell_start(id, gated("true", "echo done >> lines; echo done")))
    running = await_pgid(id)

    kill_executor()

    # The new executor asked the operation to resend, and monitors it.
    assert {^running, _journaled} = await_snapshot(id, "awaiting")
    {:monitored_by, watchers} = Process.info(op_pid(id), :monitored_by)
    assert Process.whereis(Executor) in watchers

    go(workspace)

    assert {%{"state" => %{"result" => %{"out" => "done\n"}}}, _journaled} =
             await_snapshot(id, "completed")

    refute_receive {:snapshot, %{"id" => ^id, "status" => "completed"}, _journaled}, 200
    assert lines(Path.join(workspace, "lines")) == ["done"]
  end

  test "an executor killed while a report waits on it leaves the command running", %{
    dir: dir,
    workspace: workspace
  } do
    start_node(dir)
    id = new_id()

    TestLink.hold(&match?(%{"state" => %{"pgid" => pgid}} when is_integer(pgid) and pgid > 0, &1))
    :ok = Executor.start(shell_start(id, gated("true", "echo done >> lines")))

    # The operation's report of its process group waits on the executor,
    # which waits in the link.
    assert_receive {:held, ^id, _executor}, 10_000
    kill_executor()

    assert {%{"state" => %{"pgid" => pgid}}, _journaled} = await_snapshot(id, "awaiting")
    assert group_alive?(pgid)
    go(workspace)

    assert {_completed, _journaled} = await_snapshot(id, "completed")
    refute_receive {:snapshot, %{"id" => ^id, "status" => "completed"}, _journaled}, 200
    assert lines(Path.join(workspace, "lines")) == ["done"]
  end

  # Node rule 10.
  test "a node stopped while a command runs reports the command as killed after it restarts",
       %{dir: dir} do
    start_node(dir)
    id = new_id()

    :ok = Executor.start(shell_start(id, "sleep 30"))
    pgid = await_pgid(id)["state"]["pgid"]

    :ok = stop_supervised(PhotonNode)
    refute group_alive?(pgid)

    start_node(dir)

    assert {%{"state" => %{"terminal_error" => @stopped <> _status}}, _journaled} =
             await_snapshot(id, "failed")

    refute_receive {:snapshot, %{"id" => ^id}, _journaled}, 200
  end

  ## Reattaching after an abrupt crash

  # F11.
  test "the scan reattaches to a command whose process group is in the snapshot", %{
    dir: dir,
    ops_dir: ops_dir
  } do
    id = new_id()
    pattern = "sleep 73.#{System.unique_integer([:positive])}"
    {op, pgid} = journal_running(dir, ops_dir, id, pattern)
    on_exit(fn -> System.cmd("pkill", ["-KILL", "-f", pattern]) end)
    :ok = Journal.write(ops_dir, id, %{"op" => running(op, pgid), "cancel" => false})

    start_node(dir)
    _ = :sys.get_state(op_pid(id))
    File.write!(Path.join(Journal.op_dir(ops_dir, id), "go"), "")

    assert {%{"state" => %{"result" => %{"exit_code" => 0}}}, _journaled} =
             await_snapshot(id, "completed")

    refute group_alive?(pgid)
  end

  # K1.
  test "the scan finds a command started just before a crash through its pid file", %{
    dir: dir,
    ops_dir: ops_dir
  } do
    id = new_id()
    pattern = "sleep 74.#{System.unique_integer([:positive])}"
    {op, pgid} = journal_running(dir, ops_dir, id, pattern)
    on_exit(fn -> System.cmd("pkill", ["-KILL", "-f", pattern]) end)
    File.write!(Path.join(Journal.op_dir(ops_dir, id), "pid"), "#{pgid}\n")
    :ok = Journal.write(ops_dir, id, %{"op" => running(op, 0), "cancel" => false})

    start_node(dir)
    _ = :sys.get_state(op_pid(id))
    File.write!(Path.join(Journal.op_dir(ops_dir, id), "go"), "")

    assert {%{"state" => %{"result" => %{"exit_code" => 0}}}, _journaled} =
             await_snapshot(id, "completed")
  end

  test "the scan finishes a command whose exit file was written", %{dir: dir, ops_dir: ops_dir} do
    id = new_id()
    {:ok, ready} = Request.operation(shell_start(id, "echo hi"), facts(dir))
    op_dir = Journal.op_dir(ops_dir, id)
    File.mkdir_p!(op_dir)
    File.write!(Path.join(op_dir, "out"), "hi\n")
    File.write!(Path.join(op_dir, "err"), "")
    File.write!(Path.join(op_dir, "exit"), "0\n")
    # A process group that has exited: a shell's own PID once it is gone.
    {gone, 0} = System.cmd("/bin/sh", ["-c", "echo $$"])
    gone = gone |> String.trim() |> String.to_integer()
    :ok = Journal.write(ops_dir, id, %{"op" => running(ready, gone), "cancel" => false})

    start_node(dir)

    assert {%{"state" => %{"result" => %{"out" => "hi\n", "exit_code" => 0}}}, _journaled} =
             await_snapshot(id, "completed")
  end

  ## Journal failures

  # Node rule 8.
  test "an ops directory the executor can't write runs nothing", %{
    dir: dir,
    ops_dir: ops_dir,
    workspace: workspace
  } do
    start_node(dir)
    File.chmod!(ops_dir, 0o500)
    id = new_id()

    :ok = Executor.start(shell_start(id, "touch ran"))

    assert {%{"state" => %{"terminal_error" => error}}, nil} = await_snapshot(id, "failed")
    assert error =~ "The machine couldn't record the operation: can't create"
    assert error =~ "It didn't run."
    assert op_pid(id) == nil
    refute File.exists?(Path.join(workspace, "ran"))
  end

  # Node rule 8: a result the journal can't take over a `ready` entry.
  # While `op.json.tmp` is a directory, every write of the entry fails, so
  # the shell can't record its command's start and fails without running it.
  defp journal_unwritable_ready(dir, ops_dir, id) do
    {:ok, ready} = Request.operation(shell_start(id, "touch ran"), facts(dir))
    :ok = Journal.write(ops_dir, id, %{"op" => ready, "cancel" => false})
    blocker = Path.join(Journal.op_dir(ops_dir, id), "op.json.tmp")
    File.mkdir_p!(blocker)

    start_node(dir)

    assert {%{"state" => %{"terminal_error" => error}} = failed, nil} =
             await_snapshot(id, "failed")

    assert error =~ "couldn't record the command's start, so it didn't run"
    # The ready entry is gone, so nothing can start the command from it.
    refute File.exists?(entry_file(ops_dir, id))
    File.rm_rf!(blocker)
    failed
  end

  test "a result the journal can't take is held until the ack, and the command never runs", %{
    dir: dir,
    ops_dir: ops_dir,
    workspace: workspace
  } do
    id = new_id()
    failed = journal_unwritable_ready(dir, ops_dir, id)

    # The hub asks again (its copy was lost, say): it gets the same result.
    :ok = Executor.start(shell_start(id, "touch ran", true))
    assert {^failed, nil} = await_snapshot(id, "failed")
    assert Executor.snapshots() == [failed]
    assert op_pid(id) == nil

    :ok = Executor.ack(id)
    assert Executor.snapshots() == []
    refute File.exists?(Path.join(workspace, "ran"))
  end

  test "a result the journal couldn't take doesn't run the command after a restart", %{
    dir: dir,
    ops_dir: ops_dir,
    workspace: workspace
  } do
    id = new_id()
    _failed = journal_unwritable_ready(dir, ops_dir, id)

    # The disk takes writes again, and the executor restarts and scans.
    kill_executor()
    assert Executor.snapshots() == []

    :ok = Executor.start(shell_start(id, "touch ran", true))
    assert {%{"state" => %{"terminal_error" => error}}, nil} = await_snapshot(id, "failed")
    assert error =~ "The machine has no record of this operation"
    assert op_pid(id) == nil
    refute File.exists?(Path.join(workspace, "ran"))
  end

  test "an entry that can't be read is answered as failed, and the ack removes it", %{
    dir: dir,
    ops_dir: ops_dir
  } do
    id = new_id()
    File.mkdir_p!(Journal.op_dir(ops_dir, id))
    File.write!(entry_file(ops_dir, id), "{\"op\":")

    start_node(dir)
    :ok = Executor.start(shell_start(id, "touch ran", true))

    assert {%{"state" => %{"terminal_error" => error}}, nil} = await_snapshot(id, "failed")
    assert error =~ "The machine's record of this operation can't be read"

    :ok = Executor.ack(id)
    refute File.exists?(entry_file(ops_dir, id))
  end

  ## Helpers for journaled operations

  defp facts(dir) do
    %{shell: Env.shell(), ops_dir: Path.join(dir, "ops"), workspace: Path.join(dir, "workspace")}
  end

  # A shell operation as the journal has it after its command started:
  # files ready and the `process` checkpoint stored, with `pgid` (0 if the
  # checkpoint with the group hadn't happened yet).
  defp running(op, pgid) do
    dir = Path.join(op["state"]["base_directory"], op["id"])

    Operation.advance(op, "awaiting", %{
      "phase" => "process",
      "pgid" => pgid,
      "out_path" => Path.join(dir, "out"),
      "err_path" => Path.join(dir, "err")
    })
  end

  # A `ready` operation and a process group the test started for it, as a
  # crashed node leaves them: the group's leader waits for `go` in the
  # operation's directory, then writes the `exit` file and exits, leaving
  # a background child (`child`) behind. Returns the operation and the
  # group's ID.
  defp journal_running(dir, ops_dir, id, child) do
    {:ok, ready} = Request.operation(shell_start(id, "true"), facts(dir))
    op_dir = Journal.op_dir(ops_dir, id)
    File.mkdir_p!(op_dir)
    for f <- ~w(out err), do: File.write!(Path.join(op_dir, f), "")
    {ready, start_group(op_dir, child)}
  end

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

  defp group_alive?(pgid),
    do: match?({_, 0}, System.cmd("/bin/sh", ["-c", "kill -0 -#{pgid} 2>/dev/null"]))
end
