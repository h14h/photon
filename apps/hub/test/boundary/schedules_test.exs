defmodule Photon.SchedulesTest do
  @moduledoc """
  `Photon.Schedules` through its API, on the durable harness with the
  scripted model: schedules fire through their routine task
  (`Photon.Schedules.Routine`) into a new thread, one thread or Blip's
  conversation. A thread that stays busy runs a `shell` call on `box`, a
  machine the test process connects as (`Photon.MachineOps.connect/2`)
  and never answers. Where a test needs a firing step held still, it
  stops the Scheduler and builds the state with `Tx`, since a fire step
  has nothing to block on. The rules themselves are covered in
  `test/core/schedules/rules_test.exs`.
  """

  use Photon.DataCase, async: false

  @moduletag :durable

  import Ecto.Query, only: [from: 2]
  import Photon.Eventually

  alias Photon.{Assistant, MachineOps, Projects, Schedules, Settings, Signals, Threads}
  alias Photon.Durable.{Runtime, Scheduler, Submission, TaskRecord, Tx}
  alias Photon.Schedules.{Routine, Schedule}
  alias Photon.Signals.DigestItem

  @hour 3_600_000

  setup do
    {:ok, project} =
      Projects.create(%{"purpose" => "Keep the garden watered.", "name" => "Garden"})

    :ok = Schedules.subscribe()
    %{project: project}
  end

  # An ISO 8601 time `ms` from now, as the form's hook sends it.
  defp at(ms), do: DateTime.utc_now() |> DateTime.add(ms, :millisecond) |> DateTime.to_iso8601()

  defp params(overrides) do
    Map.merge(
      %{
        "prompt" => "Check the backups",
        "at" => at(@hour),
        "repeat" => "once",
        "target" => "new_thread"
      },
      overrides
    )
  end

  # Creates a schedule and takes its own announcement.
  defp create!(project, overrides \\ %{}) do
    assert {:ok, %Schedule{} = schedule} =
             Schedules.create({:project, project.id}, params(overrides))

    project_id = project.id
    assert_receive {:schedules_changed, ^project_id}
    schedule
  end

  # Waits for the next announcement for the project (a firing); returns
  # the row as it is then.
  defp await_firing!(schedule) do
    project_id = schedule.project_id
    assert_receive {:schedules_changed, ^project_id}, 5_000
    Repo.get!(Schedule, schedule.id)
  end

  defp start!(project, text) do
    {:ok, thread} = Threads.start(project.id, text)
    thread.id
  end

  # Waits until the thread has no run in progress.
  defp idle!(thread_id) do
    :ok = Threads.subscribe(thread_id)

    if Threads.busy?(thread_id),
      do: await_change(thread_id, fn _changes -> not Threads.busy?(thread_id) end)

    thread_id
  end

  # Gives the thread a run that waits on a shell call on `box`.
  defp busy!(thread_id) do
    :ok = MachineOps.connect("box")
    {:ok, _submission} = Threads.send(thread_id, "on box: $ sleep 1000")
    assert Threads.busy?(thread_id)
    thread_id
  end

  defp scheduled(conversation_id) do
    for %{kind: "user"} = entry <- Durable.entries(conversation_id),
        entry.data["source"]["kind"] == "routine",
        do: entry
  end

  defp routine_tasks do
    Repo.all(from(t in TaskRecord, where: t.kind == "routine", order_by: t.inserted_at))
  end

  # The task once the Scheduler has run its start step, or nil.
  defp waiting(task_id) do
    case Durable.task(task_id) do
      %TaskRecord{status: "waiting"} = task -> task
      _not_yet -> nil
    end
  end

  defp stop_scheduler, do: :ok = stop_supervised!(Scheduler)

  defp start_scheduler do
    _pid = start_supervised!(Scheduler)
    :ok = Scheduler.sync()
  end

  describe "create/2" do
    test "makes the row and its routine task, and announces it, for each target", %{
      project: project
    } do
      thread_id = idle!(start!(project, "Fix the pump"))
      new_thread = create!(project, %{"repeat" => "every", "every" => "1", "unit" => "days"})
      woken = create!(project, %{"target" => thread_id, "prompt" => "Check the pump"})

      assert %Schedule{
               project_id: project_id,
               conversation_id: nil,
               every_minutes: 1_440,
               version: 1,
               created_by: "owner",
               last_outcome: nil
             } = new_thread

      assert project_id == project.id
      assert %Schedule{conversation_id: ^thread_id, every_minutes: nil} = woken

      for schedule <- [new_thread, woken] do
        task = Durable.task(schedule.task_id)
        first_at = DateTime.to_unix(schedule.first_at, :millisecond)

        assert %TaskRecord{kind: "routine", conversation_id: nil, background: true} = task
        assert task.request_id == "schedule:#{schedule.id}:v1"
        assert task.input["schedule_id"] == schedule.id
        assert task.input["first_at"] == first_at
      end

      assert Durable.task(new_thread.task_id).input["every_ms"] == 1_440 * 60_000
      assert Durable.task(woken.task_id).input["every_ms"] == nil

      assert %{state: :waiting, next_at: next_at} = Schedules.get(new_thread.id)
      assert next_at == new_thread.first_at

      assert Enum.map(Schedules.list({:project, project.id}), & &1.id) == [
               new_thread.id,
               woken.id
             ]

      assert Schedules.list(:blip) == []
    end

    test "refuses a missing project, bad fields and another project's thread", %{
      project: project
    } do
      {:ok, shed} = Projects.create(%{"name" => "Shed", "purpose" => "Fix the shed roof."})
      other = idle!(start!(shed, "Patch the roof"))

      assert Schedules.create({:project, "p_missing"}, params(%{})) == {:error, :not_found}

      assert {:error, %{prompt: _, target: _}} =
               Schedules.create(
                 {:project, project.id},
                 params(%{"prompt" => " ", "target" => other})
               )

      assert Repo.aggregate(Schedule, :count) == 0
      assert routine_tasks() == []
      refute_received {:schedules_changed, _}
    end

    test "list/1 orders by next time, and a finished one comes last", %{project: project} do
      later = create!(project, %{"at" => at(2 * @hour)})
      sooner = create!(project, %{"at" => at(@hour)})
      fired = create!(project, %{"at" => at(0)})
      assert %Schedule{last_outcome: "started"} = await_firing!(fired)

      assert [
               %{id: first, state: :waiting},
               %{id: second, state: :waiting},
               %{id: last, state: :done, next_at: nil}
             ] = Schedules.list({:project, project.id})

      assert [first, second, last] == [sooner.id, later.id, fired.id]
      idle!(Repo.get!(Schedule, fired.id).last_thread_id)
    end
  end

  test "new_params/1 starts at the next whole hour, once, in a new thread" do
    params = Schedules.new_params(~U[2026-10-08 14:05:40Z])

    assert %{"prompt" => "", "repeat" => "once", "target" => "new_thread"} = params
    assert params["at"] == "2026-10-08T15:00:00Z"
  end

  test "edit_params/1 gives a schedule's form values back", %{project: project} do
    thread_id = idle!(start!(project, "Fix the pump"))

    schedule =
      create!(project, %{
        "prompt" => "Water the beds",
        "at" => "2030-01-02T09:00:00.000Z",
        "repeat" => "every",
        "every" => "36",
        "unit" => "hours",
        "target" => thread_id
      })

    assert Schedules.edit_params(schedule) == %{
             "prompt" => "Water the beds",
             "at" => "2030-01-02T09:00:00Z",
             "repeat" => "every",
             "every" => "36",
             "unit" => "hours",
             "target" => thread_id
           }

    once = create!(project, %{"at" => "2030-01-02T09:00:00Z"})

    assert %{"repeat" => "once", "every" => "1", "unit" => "days", "target" => "new_thread"} =
             Schedules.edit_params(once)
  end

  describe "firing" do
    test "a one-off new-thread schedule starts a thread with the scheduled prompt, then finishes",
         %{project: project} do
      schedule = create!(project, %{"at" => at(1_000)})

      assert %Schedule{
               last_outcome: "started",
               last_thread_id: thread_id,
               last_run_at: %DateTime{}
             } =
               await_firing!(schedule)

      assert [%{id: ^thread_id}] = Threads.list(project.id)
      assert [first | _] = Durable.entries(thread_id)
      assert PhotonCore.Message.text_of(first.data["message"]) == "[Scheduled] Check the backups"

      assert first.data["source"] == %{
               "kind" => "routine",
               "schedule_id" => schedule.id,
               "created_by" => "owner",
               "asked_by" => nil
             }

      assert %TaskRecord{status: "done"} = Durable.task(schedule.task_id)
      assert %{state: :done, next_at: nil} = Schedules.get(schedule.id)
      idle!(thread_id)
    end

    test "the first firing of a repeating new-thread schedule starts a thread and waits again", %{
      project: project
    } do
      schedule =
        create!(project, %{
          "at" => at(0),
          "repeat" => "every",
          "every" => "5",
          "unit" => "minutes"
        })

      assert %Schedule{last_outcome: "started", last_thread_id: thread_id} =
               await_firing!(schedule)

      assert is_binary(thread_id)
      first_at = Durable.task(schedule.task_id).input["first_at"]

      assert %TaskRecord{status: "waiting", checkpoint: %{"runs" => 1, "next_at" => next_at}} =
               Durable.task(schedule.task_id)

      assert next_at == first_at + 5 * 60_000
      assert %{state: :waiting, next_at: listed} = Schedules.get(schedule.id)
      assert DateTime.to_unix(listed, :millisecond) == next_at
      idle!(thread_id)
    end

    test "a one-off for the current minute fires at once, and an edit keeping its time doesn't fire it again",
         %{project: project} do
      form = %{"at" => at(-30_000)}
      schedule = create!(project, form)

      assert %Schedule{last_outcome: "started", last_thread_id: thread_id} =
               await_firing!(schedule)

      assert {:ok, %Schedule{version: 2, task_id: task_id}} =
               Schedules.update(schedule.id, params(form), 1)

      assert task_id == schedule.task_id
      assert %{state: :done} = Schedules.get(schedule.id)
      assert [%{id: ^thread_id}] = Threads.list(project.id)
      assert [_one] = routine_tasks()
      idle!(thread_id)
    end

    test "a thread-target schedule wakes the thread, queues behind a busy run, and skips a second prompt",
         %{project: project} do
      thread_id = idle!(start!(project, "Fix the pump"))
      before = Threads.get(thread_id).active_at
      schedule = create!(project, %{"at" => at(0), "target" => thread_id})

      assert %Schedule{last_outcome: "sent", last_thread_id: ^thread_id} = await_firing!(schedule)
      assert DateTime.after?(Threads.get(thread_id).active_at, before)
      assert [entry] = scheduled(thread_id)
      assert PhotonCore.Message.text_of(entry.data["message"]) == "[Scheduled] Check the backups"
      idle!(thread_id)

      busy!(thread_id)
      assert Schedules.run_now(schedule.id) == {:ok, "queued"}
      assert Schedules.run_now(schedule.id) == {:ok, "skipped_queued"}
      assert [%Submission{status: "queued"}] = Threads.queued(thread_id)
      assert %Schedule{last_outcome: "skipped_queued"} = Repo.get!(Schedule, schedule.id)
      :ok = Threads.stop(thread_id)
    end

    test "a repeating new-thread schedule skips while its last thread is still running", %{
      project: project
    } do
      :ok = MachineOps.connect("box")

      schedule =
        create!(project, %{
          "prompt" => "on box: $ sleep 60",
          "repeat" => "every",
          "every" => "1",
          "unit" => "hours"
        })

      assert Schedules.run_now(schedule.id) == {:ok, "started"}
      assert %Schedule{last_thread_id: thread_id} = Repo.get!(Schedule, schedule.id)
      :ok = Threads.subscribe(thread_id)
      await_entry(thread_id, &(&1.kind == "assistant"))
      assert Threads.busy?(thread_id)

      assert Schedules.run_now(schedule.id) == {:ok, "skipped_running"}

      assert %Schedule{last_outcome: "skipped_running", last_thread_id: ^thread_id} =
               Repo.get!(Schedule, schedule.id)

      assert [%{id: ^thread_id}] = Threads.list(project.id)
      :ok = Threads.stop(thread_id)
    end

    test "Stop on a thread withdraws a queued scheduled prompt, and the next firing is sent", %{
      project: project
    } do
      thread_id = busy!(idle!(start!(project, "Fix the pump")))
      schedule = create!(project, %{"target" => thread_id})

      assert Schedules.run_now(schedule.id) == {:ok, "queued"}
      assert [%Submission{id: queued_id}] = Threads.queued(thread_id)

      :ok = Threads.stop(thread_id)
      idle!(thread_id)
      refute Threads.busy?(thread_id)
      assert %Submission{status: "withdrawn"} = Repo.get!(Submission, queued_id)
      assert scheduled(thread_id) == []

      assert Schedules.run_now(schedule.id) == {:ok, "sent"}
      assert [_placed] = scheduled(thread_id)
      idle!(thread_id)
    end
  end

  describe "consent" do
    setup %{project: project} do
      thread_id = idle!(start!(project, "Fix the pump"))
      Application.put_env(:photon, :mock_model, false)
      on_exit(fn -> Application.put_env(:photon, :mock_model, true) end)
      refute Settings.scheduled_work?(Settings.load())
      refute Schedules.consent?()
      %{thread_id: thread_id}
    end

    test "without it a firing is skipped, with a notice in a thread and none for a new thread", %{
      project: project,
      thread_id: thread_id
    } do
      woken = create!(project, %{"at" => at(0), "target" => thread_id})
      new_thread = create!(project, %{"at" => at(0)})
      project_id = project.id
      assert_receive {:schedules_changed, ^project_id}, 5_000
      assert_receive {:schedules_changed, ^project_id}, 5_000

      assert %Schedule{last_outcome: "skipped_consent"} = Repo.get!(Schedule, woken.id)

      assert %Schedule{last_outcome: "skipped_consent", last_thread_id: nil} =
               Repo.get!(Schedule, new_thread.id)

      assert [note] = for(%{kind: "error"} = e <- Durable.entries(thread_id), do: e)
      assert note.data["notice"]
      assert note.data["message"] =~ ~s{Skipped the scheduled prompt "Check the backups"}
      assert scheduled(thread_id) == []
      assert [%{id: ^thread_id}] = Threads.list(project.id)
    end

    test "run_now/1 fires anyway: the owner pressed the button", %{
      project: project,
      thread_id: thread_id
    } do
      schedule = create!(project, %{"target" => thread_id})
      # Without a scheduler the run it starts never reaches the model.
      stop_scheduler()

      assert Schedules.run_now(schedule.id) == {:ok, "sent"}
      assert [_entry] = scheduled(thread_id)
    end
  end

  describe "update/3" do
    test "retires the old task and arms one new task with the new request ID", %{
      project: project
    } do
      schedule = create!(project)
      project_id = project.id

      assert {:ok, %Schedule{version: 2, prompt: "Check the pumps", task_id: new_id}} =
               Schedules.update(schedule.id, params(%{"prompt" => "Check the pumps"}), 1)

      assert_receive {:schedules_changed, ^project_id}
      refute new_id == schedule.task_id
      assert %TaskRecord{abort_requested: true} = Durable.task(schedule.task_id)
      assert %TaskRecord{request_id: request_id} = Durable.task(new_id)
      assert request_id == "schedule:#{schedule.id}:v2"

      :ok = Scheduler.sync()
      assert [%TaskRecord{id: ^new_id}] = Durable.live_tasks("routine")

      assert Schedules.update(schedule.id, params(%{"prompt" => "Again"}), 1) ==
               {:error, :stale}

      assert Schedules.update("sc_missing", params(%{}), 1) == {:error, :not_found}
      assert {:error, %{at: _}} = Schedules.update(schedule.id, params(%{"at" => "soon"}), 2)
      assert %Schedule{version: 2, prompt: "Check the pumps"} = Repo.get!(Schedule, schedule.id)
    end

    test "a repeating schedule made a one-off at the time it just fired stops its timer", %{
      project: project
    } do
      form = %{"at" => at(-10_000), "repeat" => "every", "every" => "5", "unit" => "minutes"}
      schedule = create!(project, form)

      assert %Schedule{last_outcome: "started", last_thread_id: thread_id} =
               await_firing!(schedule)

      assert %TaskRecord{status: "waiting"} = Durable.task(schedule.task_id)

      assert {:ok, %Schedule{version: 2, every_minutes: nil, task_id: nil}} =
               Schedules.update(schedule.id, params(Map.put(form, "repeat", "once")), 1)

      assert %TaskRecord{abort_requested: true} = Durable.task(schedule.task_id)
      :ok = Scheduler.sync()
      assert Durable.live_tasks("routine") == []
      assert %TaskRecord{status: "aborted"} = Durable.task(schedule.task_id)
      assert %{state: :done, next_at: nil} = Schedules.get(schedule.id)
      assert [%{id: ^thread_id}] = Threads.list(project.id)
      idle!(thread_id)
    end

    test "a schedule that woke a thread, made to start new threads, doesn't wait on that thread",
         %{project: project} do
      thread_id = idle!(start!(project, "Fix the pump"))
      schedule = create!(project, %{"target" => thread_id})
      assert Schedules.run_now(schedule.id) == {:ok, "sent"}
      assert %Schedule{last_thread_id: ^thread_id} = Repo.get!(Schedule, schedule.id)
      busy!(idle!(thread_id))

      assert {:ok, %Schedule{conversation_id: nil, last_thread_id: nil}} =
               Schedules.update(schedule.id, params(%{}), 1)

      assert Schedules.run_now(schedule.id) == {:ok, "started"}
      assert %Schedule{last_thread_id: started_id} = Repo.get!(Schedule, schedule.id)
      refute started_id == thread_id
      :ok = Threads.stop(thread_id)
      idle!(started_id)
    end

    test "a firing step that commits after the update is ignored", %{project: project} do
      thread_id = idle!(start!(project, "Fix the pump"))
      stop_scheduler()
      schedule = create!(project, %{"at" => at(0), "target" => thread_id})

      # The task as the Scheduler would hand it to its fire step.
      old = Durable.task(schedule.task_id)
      first_at = old.input["first_at"]

      started =
        Durable.commit(
          &Tx.update_task(&1, old,
            status: "running",
            phase: "fire",
            checkpoint: %{"next_at" => first_at, "runs" => 0},
            runs: 1
          )
        )

      assert {:ok, %Schedule{task_id: new_id}} =
               Schedules.update(schedule.id, params(%{"target" => thread_id}), 1)

      assert Routine.step("fire", started, %Runtime{task: started}) == :ignored
      assert scheduled(thread_id) == []
      assert %Schedule{last_outcome: nil, last_run_at: nil} = Repo.get!(Schedule, schedule.id)

      start_scheduler()
      assert [%TaskRecord{id: ^new_id}] = Durable.live_tasks("routine")
      assert %TaskRecord{status: "aborted"} = Durable.task(old.id)
    end
  end

  describe "a failed task" do
    defp fail!(task, reason) do
      Durable.commit(fn tx ->
        _failed = Tx.finish(tx, task, "failed", %{"status" => "failed", "reason" => reason})
        Routine.on_fail(task, reason, tx)
      end)
    end

    test "stops the schedule and says why, until it is saved again", %{project: project} do
      schedule = create!(project, %{"repeat" => "every", "every" => "1", "unit" => "days"})
      project_id = project.id

      assert fail!(Durable.task(schedule.task_id), "boom") == :ok
      assert_receive {:schedules_changed, ^project_id}
      assert %Schedule{last_outcome: "failed"} = Repo.get!(Schedule, schedule.id)
      assert [%{state: {:stopped, "boom"}, next_at: nil}] = Schedules.list({:project, project.id})

      form = %{"repeat" => "every", "every" => "1", "unit" => "days"}
      assert {:ok, %Schedule{task_id: new_id}} = Schedules.update(schedule.id, params(form), 1)
      refute new_id == schedule.task_id
      assert %{state: :waiting, next_at: %DateTime{}} = Schedules.get(schedule.id)
    end

    test "is collected for ambient mode's next digest while it is on, and not while off", %{
      project: project
    } do
      schedule = create!(project, %{"repeat" => "every", "every" => "1", "unit" => "days"})
      assert fail!(Durable.task(schedule.task_id), "boom") == :ok
      assert Repo.all(DigestItem) == []

      _doc = Durable.commit(&Signals.put_ambient_doc_tx(&1, %{"on" => true}))
      :ok = Photon.Events.subscribe(Signals.ambient_topic())
      form = %{"repeat" => "every", "every" => "1", "unit" => "days"}
      {:ok, saved} = Schedules.update(schedule.id, params(form), 1)
      assert fail!(Durable.task(saved.task_id), "the project no longer exists") == :ok
      assert_receive {:ambient_changed}

      assert [%DigestItem{kind: "schedule_stopped"} = item] = Repo.all(DigestItem)
      key = "schedule:#{saved.task_id}:failed"

      assert {item.key, item.schedule_id, item.project_id, item.note} ==
               {key, schedule.id, project.id, "the project no longer exists"}
    end

    test "changes nothing for a task the row no longer names", %{project: project} do
      schedule = create!(project)
      project_id = project.id
      {:ok, _saved} = Schedules.update(schedule.id, params(%{}), 1)
      assert_receive {:schedules_changed, ^project_id}

      assert fail!(Durable.task(schedule.task_id), "boom") == :ok
      refute_received {:schedules_changed, _}
      assert %Schedule{last_outcome: nil} = Repo.get!(Schedule, schedule.id)
    end
  end

  test "delete/1 retires the task, and nothing fires afterwards", %{project: project} do
    stop_scheduler()
    schedule = create!(project, %{"at" => at(0)})
    project_id = project.id

    assert Schedules.delete(schedule.id) == :ok
    assert_receive {:schedules_changed, ^project_id}
    assert Schedules.get(schedule.id) == nil
    assert Schedules.delete(schedule.id) == {:error, :not_found}

    start_scheduler()
    assert %TaskRecord{status: "aborted"} = Durable.task(schedule.task_id)
    assert Threads.list(project.id) == []
    refute_received {:schedules_changed, _}
  end

  test "run_now/1 fires once without touching the task", %{project: project} do
    schedule = create!(project, %{"repeat" => "every", "every" => "1", "unit" => "hours"})
    task = eventually(fn -> waiting(schedule.task_id) end)

    assert Schedules.run_now(schedule.id) == {:ok, "started"}

    assert %Schedule{last_outcome: "started", last_thread_id: thread_id, last_run_at: %DateTime{}} =
             Repo.get!(Schedule, schedule.id)

    assert [%{id: ^thread_id}] = Threads.list(project.id)
    assert Durable.task(schedule.task_id) == task
    assert %{state: :waiting, next_at: next_at} = Schedules.get(schedule.id)
    assert next_at == schedule.first_at
    assert Schedules.run_now("sc_missing") == {:error, :not_found}
    idle!(thread_id)
  end

  describe "Blip's tool" do
    defp tool!(target, args, asked_by, request_id) do
      now = System.system_time(:millisecond)

      made = %{asked_by: asked_by, request_id: request_id, now: now}
      Durable.commit(&Schedules.tool_schedule_tx(&1, target, args, made))
    end

    defp blip_idle! do
      blip = Assistant.conversation_id()
      :ok = Durable.subscribe(blip)

      if Durable.busy?(blip),
        do: await_change(blip, fn _changes -> not Durable.busy?(blip) end)

      :ok
    end

    test "makes a project schedule like the form's, as Blip's, and its firings say who and why",
         %{project: project} do
      assert {:ok, %Schedule{} = schedule} =
               tool!(
                 {:project, project.id, nil},
                 %{"prompt" => "files", "in_minutes" => 60, "every_minutes" => 60},
                 "owner",
                 "schedule:t_tool"
               )

      project_id = project.id
      assert_receive {:schedules_changed, ^project_id}

      assert %Schedule{
               project_id: ^project_id,
               conversation_id: nil,
               created_by: "blip",
               asked_by: "owner",
               every_minutes: 60
             } = schedule

      assert Durable.task(schedule.task_id).request_id == "schedule:t_tool"
      assert [%{id: id}] = Schedules.list({:project, project.id})
      assert id == schedule.id

      assert Schedules.run_now(schedule.id) == {:ok, "started"}
      [thread] = Threads.list(project.id)
      assert [first | _] = Durable.entries(thread.id)

      assert first.data["source"] == %{
               "kind" => "routine",
               "schedule_id" => schedule.id,
               "created_by" => "blip",
               "asked_by" => "owner"
             }

      idle!(thread.id)
      :ok = blip_idle!()
    end

    test "wakes one of the project's threads, and refuses one that isn't", %{project: project} do
      thread_id = project |> start!("files") |> idle!()
      {:ok, other} = Projects.create(%{"purpose" => "Fix things.", "name" => "House"})
      theirs = other |> start!("files") |> idle!()
      args = %{"prompt" => "files", "in_minutes" => 60}

      assert {:ok, %Schedule{conversation_id: ^thread_id, asked_by: "blip"}} =
               tool!({:project, project.id, thread_id}, args, "blip", "schedule:t_wake")

      assert tool!({:project, project.id, theirs}, args, "blip", "schedule:t_theirs") ==
               {:error, "#{theirs} isn't a thread in garden."}

      assert tool!({:project, "p_gone", nil}, args, "blip", "schedule:t_gone") ==
               {:error, "That project no longer exists."}

      assert [_one] = Schedules.list({:project, project.id})
      assert Schedules.list({:project, other.id}) == []
    end

    test "makes one of Blip's own, posting into its conversation" do
      blip = Assistant.conversation_id()

      assert {:ok, %Schedule{project_id: nil, conversation_id: ^blip, asked_by: "owner"}} =
               tool!({:blip, blip}, %{"prompt" => "ping", "in_minutes" => 60}, "owner", "s:t_own")

      assert_receive {:schedules_changed, nil}
    end
  end

  describe "delete_tx/3" do
    test ":any deletes Blip's or a project's; :blip and a project's scope only their own", %{
      project: project
    } do
      theirs = create!(project)
      blip = Assistant.conversation_id()

      {:ok, own} =
        Durable.commit(
          &Schedules.tool_schedule_tx(
            &1,
            {:blip, blip},
            %{"prompt" => "ping", "in_minutes" => 60},
            %{
              asked_by: "owner",
              request_id: "schedule:t_del",
              now: System.system_time(:millisecond)
            }
          )
        )

      assert Durable.commit(&Schedules.delete_tx(&1, theirs.id, :blip)) == {:error, :not_found}

      assert Durable.commit(&Schedules.delete_tx(&1, own.id, {:project, project.id})) ==
               {:error, :not_found}

      assert Durable.commit(&Schedules.delete_tx(&1, theirs.id, :any)) == :ok
      assert Durable.commit(&Schedules.delete_tx(&1, own.id, :any)) == :ok
      assert Durable.commit(&Schedules.delete_tx(&1, own.id, :any)) == {:error, :not_found}
      assert Schedules.get(theirs.id) == nil
      assert Schedules.get(own.id) == nil
      assert Durable.task(theirs.task_id).abort_requested
    end
  end

  test "a schedule of Blip's posts into Blip's conversation" do
    blip = Assistant.conversation_id()

    schedule =
      Repo.insert!(%Schedule{
        id: "sc_morning",
        conversation_id: blip,
        prompt: "Review the day",
        first_at: DateTime.utc_now(),
        version: 1,
        created_by: "blip",
        asked_by: "owner"
      })

    assert Schedules.run_now(schedule.id) == {:ok, "sent"}
    assert_receive {:schedules_changed, nil}
    assert [entry] = scheduled(blip)

    assert entry.data["source"] == %{
             "kind" => "routine",
             "schedule_id" => "sc_morning",
             "created_by" => "blip",
             "asked_by" => "owner"
           }

    assert [%{id: "sc_morning"}] = Schedules.list(:blip)
    idle!(blip)
  end

  test "a schedule survives a hub restart and fires once", %{project: project} do
    stop_scheduler()
    schedule = create!(project, %{"at" => at(0)})

    # The hub stops with the schedule armed, and comes back.
    :ok = stop_supervised!(Photon.Durable.Store)
    _store = start_supervised!(Photon.Durable.Store)
    start_scheduler()

    assert %Schedule{last_outcome: "started", last_thread_id: thread_id} =
             await_firing!(schedule)

    assert [%{id: ^thread_id}] = Threads.list(project.id)
    assert %TaskRecord{status: "done"} = Durable.task(schedule.task_id)
    idle!(thread_id)
  end
end
