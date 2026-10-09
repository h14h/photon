defmodule Photon.AmbientTest do
  @moduledoc """
  `Photon.Ambient` through its API, on the durable harness with the
  scripted models: saving the setting arms and retires the two timers,
  digests and reviews are posted into Blip's conversation (or skipped),
  and the timers fire, survive a restart, are fenced out once retired and
  stop after an error. Which items are new and which threads are due is
  covered in `test/core/ambient/rules_test.exs`, and the words in
  `text_test.exs`; here, that the firings read, post and delete what they
  should, in one commit.

  Where Blip must be busy, it runs a `shell` call on `box`, a machine the
  test process plays and that never answers, so what is posted queues
  behind its run. The scripted Blip (`Photon.Assistant.MockAmbient`)
  answers a digest or a review in a line per thread, so its reply is
  checked only for naming them.
  """

  use Photon.DataCase, async: false

  @moduletag :durable

  import Ecto.Query, only: [from: 2]
  import Photon.Eventually
  import Photon.ConversationHelpers
  import Photon.ProjectHelpers
  import Photon.MachineOps, only: [fake_machine: 1]

  alias Photon.{Ambient, Assistant, Schedules, Signals, Threads}
  alias Photon.Ambient.{Rules, Timer}
  alias Photon.Durable.{Runtime, Scheduler, Store, Submission, TaskRecord, Tx}
  alias Photon.Schedules.Routine
  alias Photon.Signals.DigestItem
  alias Photon.Threads.Thread
  alias PhotonCore.Message

  @hour 3_600_000

  setup do
    project = garden!()

    %{project: project, blip: Assistant.conversation_id()}
  end

  ## Helpers

  defp on!(params \\ %{}), do: :ok = Ambient.configure(Map.merge(%{"ambient" => "true"}, params))
  defp off!, do: :ok = Ambient.configure(%{"ambient" => "false"})

  defp doc, do: Signals.ambient_doc()

  defp items, do: Repo.all(from(i in DigestItem, order_by: [asc: i.inserted_at, asc: i.id]))

  # The owner starts a thread that waits on `box`, then stops it.
  defp stopped!(project) do
    :ok = fake_machine("box")
    {:ok, thread} = Threads.start(project.id, "on box: $ sleep 1000")
    :ok = Durable.subscribe(thread.id)
    _call = await_entry(thread.id, &(&1.kind == "assistant"))
    :ok = Threads.stop(thread.id)
    idle!(thread.id)
  end

  # Moves a thread's last touch `days` back, so it reads as untouched.
  defp backdate!(thread_id, days) do
    at = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
    query = from(t in Thread, where: t.id == ^thread_id)
    {1, _rows} = Repo.update_all(query, set: [last_run_ended_at: at, active_at: at])
    at
  end

  # Blip's digest or review messages (`kind`), oldest first, whatever
  # their status.
  defp posted(blip, kind) do
    query =
      from(s in Submission,
        where: s.conversation_id == ^blip,
        order_by: [asc: s.inserted_at, asc: s.id]
      )

    for %Submission{content: %{"source" => %{"signals" => [%{"kind" => ^kind} | _]}}} = s <-
          Repo.all(query),
        do: s
  end

  defp text(%Submission{content: %{"parts" => [%{"text" => text}]}}), do: text
  defp ref(%Submission{content: %{"source" => %{"signals" => [ref]}}}), do: ref

  defp ambient_tasks do
    Repo.all(from(t in TaskRecord, where: t.kind == "ambient", order_by: t.inserted_at))
  end

  # The task once the Scheduler has run its start step, or nil.
  defp waiting(task_id) do
    case Durable.task(task_id) do
      %TaskRecord{status: "waiting"} = task -> task
      _not_yet -> nil
    end
  end

  defp status(task_id, status) do
    case Durable.task(task_id) do
      %TaskRecord{status: ^status} = task -> task
      _other -> nil
    end
  end

  defp stop_scheduler, do: :ok = stop_supervised!(Scheduler)

  defp start_scheduler do
    _pid = start_supervised!(Scheduler)
    :ok = Scheduler.sync()
  end

  ## The setting

  describe "configure/1" do
    test "turning it on arms both timers; the same save, or one without the switch, changes nothing" do
      :ok = Ambient.subscribe()
      before = System.system_time(:millisecond)
      on!(%{"ambient_every" => "180", "utc_offset" => "-300"})
      assert_receive {:ambient_changed}

      assert %{
               "on" => true,
               "every_minutes" => 180,
               "offset_minutes" => -300,
               "version" => 1,
               "digest_task_id" => digest_id,
               "review_task_id" => review_id,
               "on_since" => on_since,
               "stopped" => nil
             } = doc()

      assert {:ok, _on_since, 0} = DateTime.from_iso8601(on_since)

      assert [%TaskRecord{id: ^digest_id} = digest, %TaskRecord{id: ^review_id} = review] =
               Enum.sort_by(ambient_tasks(), &(&1.input["job"] != "digest"))

      assert %{"job" => "digest", "every_ms" => 10_800_000, "first_at" => digest_at} =
               digest.input

      assert digest_at >= before + 3 * @hour and digest_at <= before + 3 * @hour + 60_000
      assert digest.request_id == "ambient:digest:v1"
      assert digest.background

      assert %{"job" => "review", "every_ms" => 86_400_000, "first_at" => review_at} =
               review.input

      assert review_at == Rules.next_review(review_at - 1, -300)
      assert DateTime.from_unix!(review_at, :millisecond).hour == 14

      assert %{
               on?: true,
               every_minutes: 180,
               next_digest_at: next_digest,
               next_review_at: next_review,
               pending: %{new: 0, smaller: 0},
               last_digest: nil,
               stopped: nil,
               scripted?: true
             } = Ambient.status()

      assert DateTime.to_unix(next_digest, :millisecond) == digest_at
      assert DateTime.to_unix(next_review, :millisecond) == review_at

      saved = doc()
      on!(%{"ambient_every" => "180", "utc_offset" => "-300"})
      assert doc() == saved
      :ok = Ambient.configure(%{"user_name" => "Henry"})
      assert doc() == saved

      assert Enum.sort(Enum.map(ambient_tasks(), & &1.id)) == Enum.sort([digest_id, review_id])
    end

    test "a new interval replaces only the digest timer, and a new offset only the review timer" do
      on!(%{"utc_offset" => "0"})
      %{"digest_task_id" => digest_id, "review_task_id" => review_id} = doc()

      on!(%{"ambient_every" => "60"})
      assert %{"every_minutes" => 60, "version" => 2, "review_task_id" => ^review_id} = doc()
      new_digest = doc()["digest_task_id"]
      refute new_digest == digest_id
      assert %TaskRecord{input: %{"every_ms" => @hour}} = Durable.task(new_digest)
      assert eventually(fn -> status(digest_id, "aborted") end)

      on!(%{"utc_offset" => "330"})
      assert %{"offset_minutes" => 330, "version" => 3, "digest_task_id" => ^new_digest} = doc()
      refute doc()["review_task_id"] == review_id
      assert eventually(fn -> status(review_id, "aborted") end)
      assert Ambient.status().on?
    end

    test "turning it off retires both timers, deletes the items and withdraws a queued digest",
         %{project: project, blip: blip} do
      on!()
      %{"digest_task_id" => digest_id, "review_task_id" => review_id} = doc()
      parked = park_blip!(subscribe: true)
      _thread = idle_thread!(project, "files")
      assert %{outcome: "queued"} = Ambient.digest_now()
      [digest] = posted(blip, "digest")
      assert digest.status == "queued"
      _thread = idle_thread!(project, "files again")
      refute items() == []

      :ok = Ambient.subscribe()
      off!()
      assert_receive {:ambient_changed}

      assert %{"on" => false, "digest_task_id" => nil, "review_task_id" => nil} = doc()
      assert items() == []
      assert Repo.get!(Submission, digest.id).status == "withdrawn"
      assert eventually(fn -> status(digest_id, "aborted") end)
      assert eventually(fn -> status(review_id, "aborted") end)
      assert %{on?: false, next_digest_at: nil, next_review_at: nil} = Ambient.status()

      # From now on nothing is collected.
      _thread = idle_thread!(project, "files once more")
      assert items() == []
      unpark_blip!(parked, idle: true)
    end

    test "turning it off withdraws a queued review and clears its threads' marks", %{
      project: project,
      blip: blip
    } do
      failed = idle_thread!(project, "fail: the ladder is missing").id
      _at = backdate!(failed, 4)
      idle!(blip)
      on!()
      parked = park_blip!(subscribe: true)

      assert %{outcome: "queued", count: 1} = Ambient.review_now()
      assert [review] = posted(blip, "review")
      assert %DateTime{} = Threads.get(failed).reviewed_at

      off!()
      assert Repo.get!(Submission, review.id).status == "withdrawn"
      assert Threads.get(failed).reviewed_at == nil
      unpark_blip!(parked, idle: true)
    end
  end

  ## The digest

  describe "digest_now/0" do
    test "with nothing pending skips, and posts nothing", %{blip: blip} do
      on!()
      assert %{outcome: "skipped_nothing", count: 0} = Ambient.digest_now()
      assert posted(blip, "digest") == []
      assert %{"outcome" => "skipped_nothing", "count" => 0} = doc()["last_digest"]
      assert doc()["last_sent_at"] == nil
    end

    test "posts what is new with the smaller changes, and uses up every item once Blip answers",
         %{
           project: project,
           blip: blip
         } do
      on!()
      thread = idle_thread!(project, "files").id
      assert [%{kind: "thread_started"}, %{kind: "finished"}] = items()
      assert Ambient.status().pending == %{new: 1, smaller: 1}

      :ok = Ambient.subscribe()
      assert %{outcome: "sent", count: 2, at: at} = Ambient.digest_now()
      assert_receive {:ambient_changed}
      # Carried by the digest until Blip's run on it settles.
      assert Signals.pending() == []
      assert Enum.all?(items(), &String.starts_with?(&1.digest_key, "digest:now:"))

      assert [digest] = posted(blip, "digest")
      assert text(digest) =~ ~r/^\[Digest\] Since ambient mode was turned on/
      assert text(digest) =~ ~s{Garden / "files" (#{thread}) finished.}
      assert text(digest) =~ ~s{The user started "files" (#{thread}) in Garden.}

      assert %{
               "kind" => "digest",
               "key" => "digest:now:" <> _id,
               "items" => [
                 %{"kind" => "finished", "new" => true, "thread_id" => ^thread},
                 %{"kind" => "thread_started", "new" => false, "thread_id" => ^thread}
               ],
               "more" => 0,
               "more_smaller" => 0
             } = ref(digest)

      assert %{"text" => "[Digest delivered " <> _rest, "drop_if_answer" => "[nothing to tell]"} =
               digest.content["source"]["older"]

      assert doc()["last_sent_at"] == DateTime.to_iso8601(at)
      assert %{"outcome" => "sent", "count" => 2} = doc()["last_digest"]
      assert %{last_digest: %{outcome: "sent", count: 2}} = Ambient.status()
      idle!(blip)
      assert items() == []

      # The next one has nothing new.
      assert %{outcome: "skipped_nothing"} = Ambient.digest_now()
      assert [_digest] = posted(blip, "digest")
      assert doc()["last_sent_at"] == DateTime.to_iso8601(at)
    end

    test "Blip's reply names the thread that finished, in its project", %{
      project: project,
      blip: blip
    } do
      on!()
      thread = idle_thread!(project, "files").id
      :ok = Durable.subscribe(blip)
      assert %{outcome: "sent"} = Ambient.digest_now()

      reply = await_entry(blip, &(&1.kind == "assistant"))
      assert Message.text_of(reply.data["message"]) =~ ~r/\Afiles in Garden finished/
      refute Message.text_of(reply.data["message"]) =~ thread
      idle!(blip)
    end

    test "a finished thread the owner has seen is smaller: it waits, and sends nothing", %{
      project: project,
      blip: blip
    } do
      on!()
      thread = idle_thread!(project, "files").id
      assert Ambient.status().pending == %{new: 1, smaller: 1}
      assert Threads.mark_seen(thread) == :ok
      assert Ambient.status().pending == %{new: 0, smaller: 2}

      assert %{outcome: "skipped_nothing"} = Ambient.digest_now()
      assert posted(blip, "digest") == []
      assert length(items()) == 2
    end

    test "a second digest while the first waits in Blip's inbox skips, and the items stay", %{
      project: project,
      blip: blip
    } do
      on!()
      parked = park_blip!(subscribe: true)
      _thread = idle_thread!(project, "files")
      assert %{outcome: "queued"} = Ambient.digest_now()
      _thread = idle_thread!(project, "files again")
      waiting = Signals.pending()
      assert length(waiting) == 2

      assert %{outcome: "skipped_queued", count: 0} = Ambient.digest_now()
      assert Signals.pending() == waiting
      assert [_digest] = posted(blip, "digest")
      unpark_blip!(parked, idle: true)
    end

    test "a stopped schedule is news until the owner saves it again", %{
      project: project,
      blip: blip
    } do
      on!()
      at = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

      params = %{
        "prompt" => "Check the gutters",
        "at" => at,
        "repeat" => "every",
        "every" => "1",
        "unit" => "days",
        "target" => "new_thread"
      }

      {:ok, schedule} = Schedules.create({:project, project.id}, params)
      task = Durable.task(schedule.task_id)

      :ok =
        Durable.commit(fn tx ->
          _failed = Tx.finish(tx, task, "failed", %{"status" => "failed", "reason" => "boom"})
          Routine.on_fail(task, "boom", tx)
        end)

      assert [%{kind: "schedule_stopped", task_id: task_id}] = items()
      assert task_id == task.id
      assert Ambient.status().pending == %{new: 1, smaller: 0}

      # Saved again: it runs on a new task, so its failure is no longer news.
      {:ok, _saved} = Schedules.update(schedule.id, params, schedule.version)
      assert Ambient.status().pending == %{new: 0, smaller: 0}
      assert %{outcome: "skipped_nothing"} = Ambient.digest_now()
      assert posted(blip, "digest") == []
      assert items() == []
    end

    test "with ambient mode off it does nothing", %{blip: blip} do
      assert %{outcome: "off"} = Ambient.digest_now()
      assert %{outcome: "off"} = Ambient.review_now()
      assert posted(blip, "digest") == []
      assert doc() == %{}
    end
  end

  test "a firing without consent skips and keeps the items", %{project: project, blip: blip} do
    on!()
    _thread = idle_thread!(project, "files")

    firing = %{
      thinks?: true,
      allowed?: false,
      key: "digest:test:0",
      now: System.system_time(:millisecond)
    }

    assert %{outcome: "skipped_consent"} = Durable.commit(&Ambient.fire_tx(&1, "digest", firing))
    assert length(items()) == 2
    assert posted(blip, "digest") == []
    assert %{"outcome" => "skipped_consent"} = doc()["last_digest"]
    assert doc()["last_sent_at"] == nil
    assert %{last_digest: %{outcome: "skipped_consent"}} = Ambient.status()
  end

  describe "when Blip can't think" do
    # As if the owner signed out of ChatGPT, or a token refresh failed: the
    # hub leaves the scripted model, and nobody is signed in.
    defp signed_out!, do: Photon.TestConfig.put_env(:photon, :mock_model, false)

    test "a firing skips, posts nothing, and keeps the items and the marks", %{
      project: project,
      blip: blip
    } do
      failed = idle_thread!(project, "fail: the ladder is missing").id
      _at = backdate!(failed, 4)
      idle!(blip)
      on!()
      _thread = idle_thread!(project, "files")
      signed_out!()

      assert %{outcome: "skipped_model", count: 0} = Ambient.digest_now()
      assert %{outcome: "skipped_model", count: 0} = Ambient.review_now()
      assert length(Signals.pending()) == 2
      assert Threads.get(failed).reviewed_at == nil
      assert posted(blip, "digest") == [] and posted(blip, "review") == []
      assert %{"outcome" => "skipped_model"} = doc()["last_digest"]

      assert %{thinks?: false, last_review: %{outcome: "skipped_model"}} = Ambient.brief()
    end

    test "a digest whose run fails gives its items back for the next one", %{
      project: project,
      blip: blip
    } do
      on!()
      parked = park_blip!(subscribe: true)
      thread = idle_thread!(project, "files").id
      assert %{outcome: "queued"} = Ambient.digest_now()
      assert Signals.pending() == []

      # Blip reaches the digest after its sign-in lapsed: the request fails.
      signed_out!()
      unpark_blip!(parked, idle: true)
      [digest] = posted(blip, "digest")
      assert %{status: "unanswered"} = await_settled(blip, digest.id)
      idle!(blip)

      assert [%{kind: "thread_started"}, %{kind: "finished", thread_id: ^thread}] =
               Signals.pending()

      # Signed in again, the next digest carries them.
      Photon.TestConfig.put_env(:photon, :mock_model, true)
      assert %{outcome: "sent", count: 2} = Ambient.digest_now()
      idle!(blip)
      assert items() == []
    end

    test "a review whose run fails clears its threads' marks", %{
      project: project,
      blip: blip
    } do
      failed = idle_thread!(project, "fail: the ladder is missing").id
      _at = backdate!(failed, 4)
      idle!(blip)
      on!()
      parked = park_blip!(subscribe: true)
      assert %{outcome: "queued", count: 1} = Ambient.review_now()
      assert %DateTime{} = Threads.get(failed).reviewed_at

      signed_out!()
      unpark_blip!(parked, idle: true)
      [review] = posted(blip, "review")
      assert %{status: "unanswered"} = await_settled(blip, review.id)
      idle!(blip)

      assert Threads.get(failed).reviewed_at == nil
    end
  end

  describe "withdrawing a queued digest or review" do
    test "a withdrawn review clears its threads' marks", %{project: project, blip: blip} do
      failed = idle_thread!(project, "fail: the ladder is missing").id
      _at = backdate!(failed, 4)
      idle!(blip)
      on!()
      parked = park_blip!(subscribe: true)
      assert %{outcome: "queued"} = Ambient.review_now()
      [review] = posted(blip, "review")
      assert %DateTime{} = Threads.get(failed).reviewed_at

      assert Assistant.withdraw(review.id) == :ok
      assert Repo.get!(Submission, review.id).status == "withdrawn"
      assert Threads.get(failed).reviewed_at == nil

      # The next review lists it again.
      unpark_blip!(parked, idle: true)
      assert %{outcome: "sent", count: 1} = Ambient.review_now()
      idle!(blip)
    end

    test "a withdrawn digest drops what it carried, and leaves what came since", %{
      project: project,
      blip: blip
    } do
      on!()
      parked = park_blip!(subscribe: true)
      _thread = idle_thread!(project, "files")
      assert %{outcome: "queued"} = Ambient.digest_now()
      [digest] = posted(blip, "digest")
      later = idle_thread!(project, "files again").id

      assert Assistant.withdraw(digest.id) == :ok
      assert Repo.get!(Submission, digest.id).status == "withdrawn"
      assert Enum.map(items(), & &1.thread_id) == [later, later]
      assert Enum.all?(items(), &is_nil(&1.digest_key))
      unpark_blip!(parked, idle: true)
    end
  end

  ## The timers

  describe "the timer" do
    test "fires a digest when its time comes, then waits for the next", %{
      project: project,
      blip: blip
    } do
      on!()
      _thread = idle_thread!(project, "files")
      first_at = System.system_time(:millisecond) - 1_000
      arming = %{first_at: first_at, every_ms: @hour, version: 100}
      :ok = Durable.subscribe(blip)
      task = timer!("digest", arming)

      _entry =
        await_entry(blip, &(&1.kind == "user" and &1.data["source"]["kind"] == "signal"))

      assert [digest] = posted(blip, "digest")
      assert ref(digest)["key"] == "digest:#{task.id}:0"
      assert Signals.pending() == []

      waited = eventually(fn -> waiting(task.id) end)
      assert waited.checkpoint == %{"next_at" => first_at + @hour, "runs" => 1}
      assert %{"outcome" => "sent"} = doc()["last_digest"]
      idle!(blip)
      assert items() == []
    end

    test "a timer waiting for its time is still waiting after a restart" do
      on!()
      %{"digest_task_id" => digest_id, "review_task_id" => review_id} = doc()
      digest = eventually(fn -> waiting(digest_id) end)
      review = eventually(fn -> waiting(review_id) end)
      status = Ambient.status()

      stop_scheduler()
      :ok = stop_supervised!(Store)
      _store = start_supervised!(Store)
      start_scheduler()

      assert waiting(digest_id).waiting == digest.waiting
      assert waiting(review_id).waiting == review.waiting
      assert Ambient.status().next_digest_at == status.next_digest_at
      assert Ambient.status().next_review_at == status.next_review_at
    end

    test "a firing step of a timer replaced meanwhile commits nothing", %{
      project: project,
      blip: blip
    } do
      on!()
      %{"digest_task_id" => digest_id} = doc()
      old = eventually(fn -> waiting(digest_id) end)
      _thread = idle_thread!(project, "files")
      stop_scheduler()

      started = started!(old)
      on!(%{"ambient_every" => "60"})
      assert Timer.step("fire", started, %Runtime{task: started}) == :ignored
      assert posted(blip, "digest") == []
      assert length(items()) == 2
      assert doc()["last_digest"] == nil

      start_scheduler()
      assert eventually(fn -> status(digest_id, "aborted") end)
    end

    test "a firing step after ambient mode was turned off commits nothing", %{blip: blip} do
      on!()
      %{"review_task_id" => review_id} = doc()
      old = eventually(fn -> waiting(review_id) end)
      stop_scheduler()

      started = started!(old)
      off!()
      assert Timer.step("fire", started, %Runtime{task: started}) == :ignored
      assert posted(blip, "review") == []
      assert doc()["last_review"] == nil

      start_scheduler()
      assert eventually(fn -> status(review_id, "aborted") end)
    end

    @tag :capture_log
    test "a firing that raises stops the timer and says so, until the next save" do
      on!()
      :ok = Ambient.subscribe()

      arming = %{
        first_at: System.system_time(:millisecond) - 1_000,
        every_ms: @hour,
        version: 100
      }

      task = timer!("bogus", arming)

      assert eventually(fn -> status(task.id, "failed") end)
      assert_receive {:ambient_changed}
      assert %{"job" => "bogus", "reason" => reason} = doc()["stopped"]
      assert is_binary(reason)
      assert %{stopped: %{job: "bogus"}, next_digest_at: nil} = Ambient.status()

      :ok = Ambient.configure(%{})
      assert %{"stopped" => nil, "digest_task_id" => new_id} = doc()
      refute new_id == task.id
      assert %{stopped: nil, next_digest_at: %DateTime{}} = Ambient.status()
    end

    test "on_fail/3 for a task the doc no longer names writes nothing" do
      on!()
      saved = doc()
      later = System.system_time(:millisecond) + 10 * @hour

      task =
        Durable.create_task(
          Timer.task("digest", %{first_at: later, every_ms: @hour, version: 99})
        )

      assert Durable.commit(&Timer.on_fail(task, "boom", &1)) == :ok
      assert doc() == saved
    end
  end

  # A digest timer made directly, named on the doc in the same commit so
  # the Scheduler can't fire it before the doc names it.
  defp timer!(job, arming) do
    Durable.commit(fn tx ->
      task = Tx.create_task(tx, Timer.task(job, arming))
      doc = Signals.ambient_doc_tx(tx)
      _doc = Signals.put_ambient_doc_tx(tx, Map.put(doc, "digest_task_id", task.id))
      task
    end)
  end

  # The task as the Scheduler would hand it to its fire step.
  defp started!(task) do
    Durable.commit(
      &Tx.update_task(&1, task,
        status: "running",
        phase: "fire",
        checkpoint: task.checkpoint,
        runs: 1
      )
    )
  end

  ## The review

  describe "review_now/0" do
    test "lists the threads left alone, marks them, and lists each again only after a week", %{
      project: project,
      blip: blip
    } do
      stopped = stopped!(project)
      failed = idle_thread!(project, "fail: the ladder is missing").id
      waiting = idle_thread!(project, "ask me: which zone first").id
      recent = stopped!(project)
      unread = idle_thread!(project, "files").id
      idle!(blip)
      for id <- [stopped, waiting, unread], do: backdate!(id, 4)
      _at = backdate!(failed, 10)
      on!()

      assert %{outcome: "sent", count: 3, at: at} = Ambient.review_now()
      assert [review] = posted(blip, "review")

      # Blip's reply lists the three, by ID on the scripted model.
      reply =
        await_entry(blip, fn entry ->
          entry.kind == "assistant" and
            Message.text_of(entry.data["message"]) =~ "These have sat for a while:"
        end)

      for id <- [stopped, failed, waiting],
          do: assert(Message.text_of(reply.data["message"]) =~ "(#{id})")

      assert text(review) =~
               ~r/^\[Daily review\] 3 threads have sat untouched for 3 days or more:/

      assert [%{"thread_id" => ^failed, "state" => "failed"}, second, third] =
               ref(review)["items"]

      assert Enum.sort([second["thread_id"], third["thread_id"]]) == Enum.sort([stopped, waiting])
      assert %{"text" => "[Daily review delivered " <> _rest} = review.content["source"]["older"]

      for id <- [stopped, failed, waiting],
          do: assert(DateTime.compare(Threads.get(id).reviewed_at, at) == :eq)

      for id <- [recent, unread], do: assert(Threads.get(id).reviewed_at == nil)
      assert %{"outcome" => "sent", "count" => 3} = doc()["last_review"]
      idle!(blip)

      assert %{outcome: "skipped_nothing"} = Ambient.review_now()
      assert [_review] = posted(blip, "review")

      # A mark older than a week, after the last touch, lets it come again.
      eight_days_ago = DateTime.add(DateTime.utc_now(), -8 * 86_400, :second)
      query = from(t in Thread, where: t.id == ^failed)
      {1, _rows} = Repo.update_all(query, set: [reviewed_at: eight_days_ago])

      assert %{outcome: "sent", count: 1} = Ambient.review_now()
      assert [_first, again] = posted(blip, "review")
      assert [%{"thread_id" => ^failed}] = ref(again)["items"]
      idle!(blip)
    end
  end
end
