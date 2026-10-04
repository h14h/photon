defmodule PhotonNode.Harness.ShellTest do
  @moduledoc """
  Regression tests for the shell operation, with the test process standing
  in for the session's coordinator (registered under the session ID).
  """

  use PhotonNode.HarnessCase, async: false

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

  # Answers checkpoint calls with `:ok` until a snapshot with `status` arrives.
  defp await_status(status, timeout \\ 10_000) do
    receive do
      {:"$gen_call", from, {:op_update, _op}} ->
        GenServer.reply(from, :ok)
        await_status(status, timeout)

      {:op_update, %{"status" => ^status} = op} ->
        op

      {:op_update, _op} ->
        await_status(status, timeout)
    after
      timeout -> flunk("no #{status} snapshot")
    end
  end

  # Answers checkpoint calls with `:ok` until a snapshot with a process group arrives.
  defp await_pgid(timeout \\ 10_000) do
    receive do
      {:"$gen_call", from, {:op_update, _op}} ->
        GenServer.reply(from, :ok)
        await_pgid(timeout)

      {:op_update, %{"state" => %{"pgid" => pgid}} = op} when pgid > 0 ->
        op

      {:op_update, _op} ->
        await_pgid(timeout)
    after
      timeout -> flunk("no snapshot with a process group")
    end
  end

  defp gone?(pattern) do
    {output, _status} = System.cmd("pgrep", ["-f", pattern])
    output == ""
  end

  defp kill_all(pattern), do: System.cmd("pkill", ["-KILL", "-f", pattern])

  # Coordinator F3: the command started before its "process" checkpoint was
  # stored, so a coordinator that was down could later start it again.
  test "a command doesn't start until its coordinator has stored the checkpoint", %{
    workspace: workspace
  } do
    marker = Path.join(workspace, "ran")
    op = translated_op("nobody_home", "touch #{marker}", workspace)
    _ = Ops.add(op, "nobody_home")

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
    {:ok, _} = Registry.register(PhotonNode.SessionRegistry, "fake8", nil)
    pattern = "sleep 61.#{System.unique_integer([:positive])}"
    on_exit(fn -> kill_all(pattern) end)
    op = translated_op("fake8", pattern, workspace)

    Ops.add(op, "fake8")
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
    {:ok, _} = Registry.register(PhotonNode.SessionRegistry, "fake11", nil)
    pattern = "sleep 62.#{System.unique_integer([:positive])}"
    on_exit(fn -> kill_all(pattern) end)

    op = translated_op("fake11", "true", workspace)
    dir = Path.join(op["state"]["base_directory"], op["id"])
    File.mkdir_p!(dir)
    pgid = start_group(dir, pattern)

    _ = Ops.add(recovered(op, dir, pgid), "fake11")
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
    {:ok, _} = Registry.register(PhotonNode.SessionRegistry, "fakek1", nil)
    pattern = "sleep 63.#{System.unique_integer([:positive])}"
    on_exit(fn -> kill_all(pattern) end)

    op = translated_op("fakek1", "true", workspace)
    dir = Path.join(op["state"]["base_directory"], op["id"])
    File.mkdir_p!(dir)
    pgid = start_group(dir, pattern)
    File.write!(Path.join(dir, "pid"), "#{pgid}\n")

    _ = Ops.add(recovered(op, dir, 0), "fakek1")
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
    {:ok, _} = Registry.register(PhotonNode.SessionRegistry, "fakekill", nil)
    pattern = "sleep 64.#{System.unique_integer([:positive])}"
    on_exit(fn -> kill_all(pattern) end)
    op = translated_op("fakekill", "trap '' TERM; #{pattern}", workspace)

    {:ok, pid} = Ops.add(op, "fakekill")
    await_pgid()
    send(pid, :cancel)

    # The group ignores SIGTERM, so it lives until SIGKILL five seconds on.
    assert %{killing: %{}} = :sys.get_state(pid, 1_000)
    send(pid, :resend)

    assert_receive {:op_update, %{"status" => "awaiting"}}, 10_000

    assert %{"state" => %{"terminal_error" => "shell operation canceled"}} =
             await_status("canceled")

    assert gone?(pattern)
  end
end
