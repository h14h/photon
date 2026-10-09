defmodule Photon.ThreadsStateTest do
  @moduledoc """
  A thread's recorded run facts and its state through `Photon.Threads`, on
  the durable harness with the scripted thread (`ask me:` and `fail:`). The
  state rules themselves are covered in `test/core/threads/state_test.exs`.
  """

  use Photon.DataCase, async: false

  @moduletag :durable

  alias Photon.Durable.TaskRecord
  alias Photon.{Projects, Threads}
  alias Photon.Threads.Thread

  import Ecto.Query, only: [from: 2]

  setup do
    {:ok, project} =
      Projects.create(%{"purpose" => "Keep the garden watered.", "name" => "Garden"})

    :ok = Projects.subscribe()
    %{project: project}
  end

  # Stands in for a connected machine that takes commands and never
  # answers, so a shell call on it keeps its thread running.
  defp fake_machine(name) do
    {:ok, _owner} =
      Registry.register(Photon.MachineRegistry, name, %{
        "platform" => "test",
        "workspace" => "/w",
        "version" => "0",
        "capabilities" => ["ops:2"]
      })
  end

  defp start!(project, text, opts \\ []) do
    {:ok, thread} = Durable.commit(&Threads.start_tx(&1, project.id, text, opts))
    thread
  end

  # Starts a thread and waits until its run has ended; returns its ID.
  defp ended!(project, text), do: idle!(start!(project, text).id)

  # Waits until the thread has no run in progress, then lets every
  # announcement of the commit that ended it arrive and drops them all, so
  # a test hears only what it does next.
  defp idle!(thread_id) do
    :ok = Threads.subscribe(thread_id)

    if Threads.busy?(thread_id),
      do: await_change(thread_id, fn _changes -> not Threads.busy?(thread_id) end)

    _state = :sys.get_state(Photon.Durable.Store)
    drain()
    thread_id
  end

  defp drain do
    receive do
      {:projects_changed, _project_id} -> drain()
      {:durable, _id, _changes} -> drain()
    after
      0 -> :ok
    end
  end

  # Starts a thread whose run waits on a shell call on `box`.
  defp running!(project) do
    thread = start!(project, "on box: $ sleep 1000")
    :ok = Threads.subscribe(thread.id)
    await_entry(thread.id, &(&1.kind == "assistant"))
    assert Threads.busy?(thread.id)
    thread
  end

  defp state(thread_id), do: Threads.state(thread_id).state

  describe "a run's end" do
    test "a finished run records done and its note, and announces it", %{project: project} do
      thread = start!(project, "files")
      project_id = project.id
      assert_receive {:projects_changed, ^project_id}

      :ok = Threads.subscribe(thread.id)
      drain_until_ended(thread.id)
      assert_received {:projects_changed, ^project_id}

      assert %Thread{
               last_run_status: "done",
               last_run_ended_at: %DateTime{},
               last_run_asked: false,
               last_run_note: "This project has no context files yet."
             } = Threads.get(thread.id)

      assert state(thread.id) == :unread
    end

    test "ask me: records that the run ended asking, so the thread waits on the owner", %{
      project: project
    } do
      id = ended!(project, "ask me: which zone should I water first")

      assert %Thread{
               last_run_status: "done",
               last_run_asked: true,
               last_run_note: "which zone should I water first?"
             } = Threads.get(id)

      assert state(id) == :waiting
    end

    test "fail: records the failure and its reason after one model request", %{project: project} do
      id = ended!(project, "fail: the pump is unplugged")

      assert %Thread{last_run_status: "failed", last_run_asked: false, last_run_note: note} =
               Threads.get(id)

      assert note =~ "the pump is unplugged"
      assert state(id) == :failed

      # One model request: the generation's request step ran once, with no
      # retry, and left one error.
      assert [%TaskRecord{runs: 1}] =
               Repo.all(
                 from(t in TaskRecord, where: t.conversation_id == ^id and t.kind == "generation")
               )

      assert Enum.count(entry_kinds(id), &(&1 == "error")) == 1
    end

    test "a Stop records stopped, with no note", %{project: project} do
      fake_machine("box")
      thread = running!(project)
      :ok = Threads.stop(thread.id)
      idle!(thread.id)

      assert %Thread{last_run_status: "stopped", last_run_note: nil, last_run_ended_at: %{}} =
               Threads.get(thread.id)

      assert state(thread.id) == :idle
    end
  end

  describe "the settle hook is total" do
    # The failed run is logged.
    @tag :capture_log
    test "a thread conversation with no row fails and records nothing, and the Scheduler lives" do
      scheduler = Process.whereis(Photon.Durable.Scheduler)
      conversation = Durable.create_conversation("thread")
      :ok = Durable.subscribe(conversation.id)

      # With no row there is no project, so the run fails before its model
      # request, in the Scheduler's fail commit, which runs the hook.
      {:ok, submission} = Durable.submit(conversation.id, "files")
      assert %{status: "unanswered"} = await_settled(conversation.id, submission.id)

      assert Threads.get(conversation.id) == nil
      assert Process.whereis(Photon.Durable.Scheduler) == scheduler
    end
  end

  # Waits for the run the thread is on to end, without dropping its
  # announcements.
  defp drain_until_ended(thread_id) do
    if Threads.busy?(thread_id),
      do: await_change(thread_id, fn _changes -> not Threads.busy?(thread_id) end)

    _state = :sys.get_state(Photon.Durable.Store)
    :ok
  end

  describe "the board" do
    test "running while it runs and unread after, with the project", %{project: project} do
      fake_machine("box")
      running = running!(project)
      finished = ended!(project, "files")

      board = Threads.board(:all)
      assert Enum.map(board, & &1.id) == [finished, running.id]

      assert [
               %{state: :unread, asking_blip?: false, questions: []},
               %{state: :running, thread: %Thread{}}
             ] = board

      assert Enum.map(Threads.board({:project, project.id}), & &1.id) == [finished, running.id]
      assert Threads.board({:project, "p_missing"}) == []
      assert Threads.state("c_missing") == nil

      :ok = Threads.stop(running.id)
      idle!(running.id)
    end

    test "the sidebar gives each listed thread its state", %{project: project} do
      finished = ended!(project, "files")
      failed = ended!(project, "fail: no water")

      assert [%{threads: threads}] = Threads.sidebar(5)

      assert Enum.map(threads, &{&1.id, &1.state, &1.running?}) == [
               {failed, :failed, false},
               {finished, :unread, false}
             ]
    end

    test "needs_you_count/0 counts waiting, failed and unread threads", %{project: project} do
      assert Threads.needs_you_count() == 0

      _finished = ended!(project, "files")
      failed = ended!(project, "fail: no water")
      _asked = ended!(project, "ask me: which zone?")
      fake_machine("box")
      stopped = running!(project)
      :ok = Threads.stop(stopped.id)
      idle!(stopped.id)

      assert Threads.needs_you_count() == 3
      assert Threads.mark_all_seen() == 1
      assert Threads.needs_you_count() == 2
      assert Threads.resolve(failed) == :ok
      assert Threads.needs_you_count() == 1
    end
  end

  describe "seen" do
    test "mark_seen/1 makes an unread thread idle and announces once", %{project: project} do
      id = ended!(project, "files")
      assert state(id) == :unread
      project_id = project.id

      assert Threads.mark_seen(id) == :ok
      assert_receive {:projects_changed, ^project_id}
      assert %Thread{seen_at: %DateTime{}} = Threads.get(id)
      assert %{state: :idle, thread: thread} = Threads.state(id)
      assert Threads.State.label(:idle, thread) == "Done"

      assert Threads.mark_seen(id) == :ok
      _state = :sys.get_state(Photon.Durable.Store)
      refute_received {:projects_changed, _}

      assert Threads.mark_seen("c_missing") == {:error, :not_found}
    end

    test "mark_seen/1 leaves a failed thread as it is", %{project: project} do
      id = ended!(project, "fail: no water")
      assert Threads.mark_seen(id) == :ok
      _state = :sys.get_state(Photon.Durable.Store)
      refute_received {:projects_changed, _}
      assert %Thread{seen_at: nil} = Threads.get(id)
      assert state(id) == :failed
    end

    test "a run that ends after the owner looked is unread again", %{project: project} do
      id = ended!(project, "files")
      :ok = Threads.mark_seen(id)
      {:ok, _submission} = Threads.send(id, "files")
      idle!(id)
      assert state(id) == :unread
    end

    test "mark_all_seen/0 marks every unread thread, announcing each project once", %{
      project: project
    } do
      {:ok, other} = Projects.create(%{"purpose" => "Fix the shed.", "name" => "Shed"})
      one = ended!(project, "files")
      two = ended!(project, "read notes.md")
      three = ended!(other, "files")
      failed = ended!(project, "fail: no water")

      assert Threads.mark_all_seen() == 3
      project_id = project.id
      other_id = other.id
      assert_receive {:projects_changed, ^project_id}
      assert_receive {:projects_changed, ^other_id}
      refute_received {:projects_changed, _}

      assert Enum.map([one, two, three, failed], &state/1) == [:idle, :idle, :idle, :failed]
      assert Threads.mark_all_seen() == 0
    end
  end

  describe "resolve and reopen" do
    test "resolve/1 makes a failed thread idle, reopen/1 brings it back", %{project: project} do
      id = ended!(project, "fail: no water")
      project_id = project.id

      assert Threads.resolve(id) == :ok
      assert_receive {:projects_changed, ^project_id}

      assert %{state: :idle, thread: %Thread{resolved_at: %DateTime{}} = thread} =
               Threads.state(id)

      assert Threads.State.label(:idle, thread) == "Resolved"

      assert Threads.reopen(id) == :ok
      assert_receive {:projects_changed, ^project_id}
      assert state(id) == :failed

      assert Threads.resolve("c_missing") == {:error, :not_found}
      assert Threads.reopen("c_missing") == {:error, :not_found}
    end

    test "a new message clears it", %{project: project} do
      id = ended!(project, "fail: no water")
      :ok = Threads.resolve(id)
      {:ok, _submission} = Threads.send(id, "files")
      assert %Thread{resolved_at: nil} = Threads.get(id)
      idle!(id)
      assert state(id) == :unread
    end

    test "input queued before a running thread was resolved clears it when it runs", %{
      project: project
    } do
      fake_machine("box")
      thread = running!(project)
      {:ok, queued} = Threads.send(thread.id, "fail: no water")
      assert queued.status == "queued"

      # Resolved while running, with the follow-up already waiting.
      :ok = Threads.resolve(thread.id)

      [shell] =
        Repo.all(
          from(t in TaskRecord, where: t.conversation_id == ^thread.id and t.kind == "tool")
        )

      _aborted = Durable.abort_task(shell.id)
      await_settled(thread.id, queued.id)
      idle!(thread.id)

      assert %Thread{resolved_at: nil, last_run_status: "failed"} = Threads.get(thread.id)
      assert state(thread.id) == :failed
    end

    test "a run that was going when the owner resolved stays resolved", %{project: project} do
      fake_machine("box")
      thread = running!(project)
      :ok = Threads.resolve(thread.id)
      :ok = Threads.stop(thread.id)
      idle!(thread.id)

      assert %Thread{resolved_at: %DateTime{}} = Threads.get(thread.id)
      assert state(thread.id) == :idle
    end
  end

  describe "started_by" do
    test "is the owner, Blip or a schedule, from the first message's source", %{
      project: project
    } do
      {:ok, owner} = Threads.start(project.id, "files")
      blip = start!(project, "files", source: %{"kind" => "blip"})

      schedule =
        start!(project, "[Scheduled] files",
          source: %{"kind" => "routine", "schedule_id" => "sc_1"},
          request_id: "schedule:sc_1:t_1:0"
        )

      assert Threads.get(owner.id).started_by == "owner"
      assert Threads.get(blip.id).started_by == "blip"
      assert Threads.get(schedule.id).started_by == "schedule"

      for id <- [owner.id, blip.id, schedule.id], do: idle!(id)
    end
  end
end
