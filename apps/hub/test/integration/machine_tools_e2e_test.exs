defmodule Photon.MachineToolsE2ETest do
  @moduledoc """
  Blip's machine tools against a real node: the hub's durable harness, the
  real node channel and a real `PhotonNode` (executor, journal and shell
  processes) talking over a websocket, as the hub's own `local` node does in
  development.

  The test endpoint has `server: false`, so each test starts a Bandit
  listener for `PhotonWeb.Endpoint` on a free loopback port and points the
  node at it. Bandit serves the endpoint's node socket in the test env, so a
  fallback (a bridge process joining through `Phoenix.ChannelTest`) isn't
  needed. The node dials in with the built-in node's key
  (`Photon.NodeKeys.local_token/0`), which loopback may use, as machine
  `local`.

  Blip and threads are driven with their scripted models (`config
  :photon, :mock_model`): `on local: $ <command>` calls `shell`, and `on
  local: look at <path>` calls `view_image`. The offline limit is raised to
  a minute, so a node that is restarted on purpose comes back long before a
  call gives up.

  The thread test checks what only a real node shows: a thread's commands
  run in its project's folder, `<workspace>/<slug>`, which the node makes on
  first use, and the project's threads share it.

  The schedule test puts skills and schedules on the same path: a project
  schedule's durable task fires on time and starts a thread whose scheduled
  prompt runs on the node in the project's folder, and that thread loads a
  skill turned on for the project.

  The coordinator test walks Blip's coordinator path on the node: Blip
  starts a thread that runs in its project's folder and hears how it ended,
  the thread asks Blip one question Blip answers from its memory and one it
  passes to the owner, and the activity log says who asked for each thing
  Blip did.

  The ambient mode test walks ambient mode on the node: a thread the owner
  started finishes there unseen, a digest tells Blip and Blip tells the
  owner, a second digest has nothing to send, the daily review raises a
  stopped thread and a failed one, and once ambient mode is off a finished
  thread leaves nothing for a digest and the timers are gone.
  """

  use Photon.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Photon.Eventually

  alias Photon.{
    Activity,
    Ambient,
    Assistant,
    Machines,
    Projects,
    Questions,
    Schedules,
    Signals,
    Skills,
    Threads
  }

  alias Photon.Activity.Action
  alias Photon.Durable.TaskRecord
  alias Photon.Machines.Op
  alias Photon.Questions.Question
  alias Photon.Signals.DigestItem
  alias Photon.Threads.Thread
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

  # Starts a thread in `project` and waits until its run is over, which
  # with the scripted model is after it relays its one tool result.
  defp run_thread!(project, text) do
    {:ok, thread} = Threads.start(project.id, text)
    await_idle(thread.id)
    thread.id
  end

  # Waits until the thread has a tool result and no run in progress.
  defp await_idle(thread_id) do
    assert eventually(
             fn -> results(thread_id) != [] and not Threads.busy?(thread_id) end,
             @wait
           )
  end

  # The output of the thread's one shell call.
  defp output(thread_id) do
    assert [%{"status" => "ok", "message" => message}] = results(thread_id)
    Message.text_of(message)
  end

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

  # The thread's open question once it has `status`.
  defp open_question(thread_id, status) do
    eventually(
      fn ->
        case Questions.open_by_thread([thread_id]) do
          %{^thread_id => [%Question{status: ^status} = question]} -> question
          _other -> nil
        end
      end,
      @wait
    )
  end

  # The text of the thread's newest `ask_blip` result, once its message
  # has settled.
  defp ask_blip!(thread_id, submission_id) do
    assert %{status: "done"} = await_settled(thread_id, submission_id, @wait)

    assert %{"status" => "ok", "message" => message} =
             thread_id |> results() |> Enum.filter(&(&1["name"] == "ask_blip")) |> List.last()

    Message.text_of(message)
  end

  # Activity rows once one matches each of `wanted`, in that order.
  defp activity!(wanted) do
    eventually(
      fn ->
        {rows, _more?} = Activity.list(limit: 500)
        found = Enum.map(wanted, fn fun -> Enum.find(rows, fun) end)
        if Enum.all?(found), do: found
      end,
      @wait
    )
  end

  # Waits until the thread's run has ended, however it ended.
  defp await_ended(thread_id) do
    assert eventually(
             fn -> not Threads.busy?(thread_id) and Threads.get(thread_id).last_run_ended_at end,
             @wait
           )
  end

  # Waits until Blip has no run in progress.
  defp await_blip_idle(c), do: assert(eventually(fn -> not Durable.busy?(c) end, @wait))

  # The op of the call `conversation_id` has in flight.
  defp open_op(conversation_id) do
    eventually(
      fn ->
        Repo.one(
          from(o in Op, where: o.conversation_id == ^conversation_id and o.status != "closed")
        )
      end,
      @wait
    )
  end

  # Blip's messages that ambient mode posted (`kind` is "digest" or
  # "review"), oldest first.
  defp ambient_entries(c, kind) do
    for %{
          kind: "user",
          data: %{"source" => %{"kind" => "signal", "signals" => [%{"kind" => ^kind} | _]}}
        } =
          entry <- Durable.entries(c),
        do: entry
  end

  # Moves a thread's last touch four days back, past the review's 72 hours.
  defp backdate!(thread_id) do
    at = DateTime.add(DateTime.utc_now(), -4 * 86_400, :second)
    query = from(t in Thread, where: t.id == ^thread_id)
    {1, _rows} = Repo.update_all(query, set: [last_run_ended_at: at, active_at: at])
    :ok
  end

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

    [{channel, _info}] = Registry.lookup(Photon.MachineRegistry, "local")
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

  test "a thread's commands run in its project's folder, made on first use and shared by the project's threads",
       %{node: node} do
    start_node(node)

    {:ok, project} =
      Projects.create(%{"name" => "Garden", "purpose" => "Keep the garden watered."})

    folder = Path.join(workspace(node), project.slug)
    refute File.exists?(folder)

    first = run_thread!(project, "on local: $ pwd; echo hi > from-first.txt")

    assert String.ends_with?(String.trim(output(first)), "/workspace/#{project.slug}")
    assert File.dir?(folder)
    assert File.read!(Path.join(folder, "from-first.txt")) == "hi\n"
    assert reply(first) =~ "/workspace/#{project.slug}"

    second = run_thread!(project, "on local: $ ls")

    assert output(second) =~ "from-first.txt"
    refute File.exists?(Path.join(workspace(node), "from-first.txt"))
  end

  test "a project schedule starts a thread that runs on the node, and the thread loads the project's skill",
       %{node: node} do
    start_node(node)

    {:ok, project} =
      Projects.create(%{"name" => "Greeter", "purpose" => "Greet whoever asks."})

    {:ok, skill} =
      Skills.create(%{
        "name" => "say-hello",
        "description" => "Greet someone.",
        "instructions" => "Run `echo hello` when asked to greet."
      })

    :ok = Skills.enable(skill.id, {:project, project.id})

    at = DateTime.utc_now() |> DateTime.add(1, :second) |> DateTime.to_iso8601()

    {:ok, schedule} =
      Schedules.create({:project, project.id}, %{
        "prompt" => "on local: $ pwd",
        "at" => at,
        "repeat" => "once",
        "target" => "new_thread"
      })

    # The routine task waits for its time, then starts the thread.
    started =
      eventually(
        fn ->
          case Schedules.get(schedule.id) do
            %{schedule: %{last_outcome: "started", last_thread_id: id}} -> id
            _not_yet -> nil
          end
        end,
        @wait
      )

    assert is_binary(started)
    assert [%{id: ^started}] = Threads.list(project.id)
    assert %{state: :done} = Schedules.get(schedule.id)

    await_idle(started)
    assert String.ends_with?(String.trim(output(started)), "/workspace/#{project.slug}")

    :ok = Threads.subscribe(started)
    {:ok, submission} = Threads.send(started, "load skill say-hello")
    assert %{status: "done"} = await_settled(started, submission.id, @wait)

    assert %{"status" => "ok", "message" => message, "details" => %{"skill" => "say-hello"}} =
             List.last(results(started))

    assert Message.text_of(message) =~ "Run `echo hello` when asked to greet."
  end

  test "Blip coordinates a thread on the node: starts it, hears how it ended, answers its question from memory and passes another to the owner",
       %{conversation: c, node: node} do
    start_node(node)

    {:ok, project} =
      Projects.create(%{"name" => "Garden", "purpose" => "Keep the garden watered."})

    :ok = Assistant.put_memory("- deploy branch: staging")

    # Blip starts a thread for the owner; it runs on the node in the
    # project's folder.
    {:ok, s} = Assistant.send("start thread in garden: on local: $ pwd")
    assert %{status: "done"} = await_settled(c, s.id, @wait)
    assert [%{id: thread_id}] = Threads.list(project.id)
    :ok = Threads.subscribe(thread_id)
    await_idle(thread_id)

    assert String.ends_with?(String.trim(output(thread_id)), "/workspace/garden")

    assert %{started_by: "blip", last_run_status: "done", last_run_asked: false} =
             Threads.get(thread_id)

    # Blip hears how the thread it started ended, and tells the owner.
    update =
      await_entry(
        c,
        &(&1.kind == "user" and &1.data["source"]["kind"] == "signal"),
        @wait
      )

    assert Message.text_of(update.data["message"]) =~ "[Thread update]"
    title = Threads.get(thread_id).title

    told =
      await_entry(
        c,
        &(&1.kind == "assistant" and Message.text_of(&1.data["message"]) =~ "in Garden finished"),
        @wait
      )

    assert Message.text_of(told.data["message"]) == "#{title} in Garden finished."

    # The thread asks Blip something its memory settles.
    {:ok, asked} = Threads.send(thread_id, "ask blip: which deploy branch?")
    assert ask_blip!(thread_id, asked.id) == "Blip answered: staging"

    # And something it doesn't: Blip passes it to the owner, whose answer
    # goes straight to the thread.
    {:ok, asked} = Threads.send(thread_id, "ask blip: what colour is the gate?")
    question = open_question(thread_id, "with_owner")
    assert %Question{passed_by: "blip", question: "what colour is the gate?"} = question
    assert %{state: :waiting} = Threads.state(thread_id)

    assert {:ok, %Question{status: "answered", answered_by: "owner"}} =
             Questions.answer(question.id, "green")

    assert ask_blip!(thread_id, asked.id) =~ ~r/They answered: green$/
    assert %{state: :unread, questions: []} = Threads.state(thread_id)

    # The log says who asked for each thing Blip did.
    [started, message, answered, passed] =
      activity!([
        &(&1.kind == "call" and &1.tool == "start_thread"),
        &(&1.kind == "message" and &1.origin == "follow_up"),
        &(&1.kind == "call" and &1.tool == "answer_question"),
        &(&1.kind == "call" and &1.tool == "ask_owner")
      ])

    assert %Action{origin: "owner", origin_id: nil, thread_id: ^thread_id, status: "ok"} =
             started

    assert %Action{origin_id: ^thread_id, summary: "Told you: " <> _told} = message
    assert %Action{origin: "thread", origin_id: ^thread_id, status: "ok"} = answered
    assert %Action{origin: "thread", origin_id: ^thread_id, status: "ok"} = passed
  end

  test "ambient mode on the node: a digest tells Blip of an unseen finish, the review raises quiet threads, and off leaves nothing",
       %{conversation: c, node: node, ops_dir: ops_dir} do
    start_node(node)

    {:ok, project} =
      Projects.create(%{"name" => "Garden", "purpose" => "Look after the garden."})

    :ok = Ambient.configure(%{"ambient" => "true"})
    %{"digest_task_id" => digest_task, "review_task_id" => review_task} = Signals.ambient_doc()

    assert %{on?: true, next_digest_at: %DateTime{}, next_review_at: %DateTime{}} =
             Ambient.status()

    # A thread the owner started finishes on the node, and nobody opens it.
    fixed = run_thread!(project, "on local: $ echo pump fixed")
    assert output(fixed) == "pump fixed\n"
    assert %{last_run_status: "done", seen_at: nil, started_by: "owner"} = Threads.get(fixed)
    assert Ambient.status().pending == %{new: 1, smaller: 1}

    # The digest tells Blip, and Blip tells the owner, in its own words.
    assert %{outcome: "sent", count: 2} = Ambient.digest_now()
    assert [digest] = ambient_entries(c, "digest")
    assert Message.text_of(digest.data["message"]) =~ "[Digest]"
    assert Message.text_of(digest.data["message"]) =~ "(#{fixed}) finished"
    title = Threads.get(fixed).title

    told =
      await_entry(
        c,
        &(&1.kind == "assistant" and Message.text_of(&1.data["message"]) =~ "in Garden finished"),
        @wait
      )

    assert Message.text_of(told.data["message"]) =~ "#{title} in Garden finished: pump fixed"

    [message] =
      activity!([
        &(&1.kind == "message" and &1.origin == "follow_up" and &1.origin_id == "digest")
      ])

    assert %Action{tool: nil, summary: "Told you: " <> _told} = message
    assert Repo.all(DigestItem) == []
    await_blip_idle(c)

    # A second digest has nothing new, and posts nothing.
    assert %{outcome: "skipped_nothing", count: 0} = Ambient.digest_now()
    assert [_digest] = ambient_entries(c, "digest")

    # The owner stops one thread mid-command, and another fails.
    {:ok, quiet} = Threads.start(project.id, "on local: $ sleep 600")
    %Op{id: op_id} = open_op(quiet.id)
    await_running(ops_dir, op_id)
    :ok = Threads.stop(quiet.id)
    await_ended(quiet.id)
    assert eventually(fn -> match?(%Op{status: "closed"}, Repo.get(Op, op_id)) end, @wait)

    {:ok, failed} = Threads.start(project.id, "fail: the ladder is missing")
    await_ended(failed.id)
    assert %{last_run_status: "failed"} = Threads.get(failed.id)

    # The failure reached Blip as a thread update, as in quiet mode; once
    # Blip is done with it, both threads are left alone for days.
    await_blip_idle(c)
    :ok = backdate!(quiet.id)
    :ok = backdate!(failed.id)

    assert %{outcome: "sent", count: 2, at: at} = Ambient.review_now()
    assert [review] = ambient_entries(c, "review")
    assert Message.text_of(review.data["message"]) =~ "[Daily review] 2 threads"

    listed =
      await_entry(
        c,
        &(&1.kind == "assistant" and
            Message.text_of(&1.data["message"]) =~ "These have sat for a while:"),
        @wait
      )

    for id <- [quiet.id, failed.id] do
      assert Message.text_of(listed.data["message"]) =~ "(#{id})"
      assert DateTime.compare(Threads.get(id).reviewed_at, at) == :eq
    end

    _rows =
      activity!([
        &(&1.kind == "message" and &1.origin == "follow_up" and &1.origin_id == "review")
      ])

    await_blip_idle(c)

    # Off: the timers are retired, and a thread that finishes now leaves
    # nothing for a digest.
    :ok = Ambient.configure(%{"ambient" => "false"})
    assert %{on?: false, next_digest_at: nil, next_review_at: nil} = Ambient.status()

    checked = run_thread!(project, "on local: $ echo pump checked")
    assert output(checked) == "pump checked\n"
    assert Repo.all(DigestItem) == []

    for task_id <- [digest_task, review_task] do
      assert eventually(
               fn -> match?(%TaskRecord{status: "aborted"}, Durable.task(task_id)) end,
               @wait
             )
    end
  end
end
