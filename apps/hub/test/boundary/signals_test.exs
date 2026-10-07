defmodule Photon.SignalsTest do
  @moduledoc """
  Signals to Blip through the threads' settle hook and `Photon.Signals`
  (section 3 of `docs/plans/step-4-blip-as-coordinator.md`), on the
  durable harness with the scripted models. Which settles become signals
  is covered cell by cell in `test/core/signals/rules_test.exs`; here, that
  the hook posts them, and how they and `ask_blip` questions join Blip's
  inbox.

  Blip is kept busy by a `shell` call on `box`, a machine the test process
  plays and that never answers, so signals queue behind its run.
  """

  use Photon.DataCase, async: false

  @moduletag :durable

  import Ecto.Query, only: [from: 2]

  import Photon.MachineOps, only: [snapshot: 2]

  alias Photon.{Assistant, Machines, Projects, Questions, Schedules, Signals, Threads}
  alias Photon.Durable.{Submission, TaskRecord}
  alias Photon.Schedules.Schedule
  alias Photon.Signals.DigestItem

  setup do
    {:ok, project} =
      Projects.create(%{"purpose" => "Keep the garden watered.", "name" => "Garden"})

    blip = Assistant.conversation_id()
    :ok = Durable.subscribe(blip)
    %{project: project, blip: blip}
  end

  defp fake_machine(name) do
    {:ok, _owner} =
      Registry.register(Photon.MachineRegistry, name, %{
        "platform" => "test",
        "workspace" => "/w",
        "version" => "0",
        "capabilities" => ["ops:2"]
      })
  end

  @blip_source %{"kind" => "blip"}

  defp start!(project, text, opts) do
    {:ok, thread} = Durable.commit(&Threads.start_tx(&1, project.id, text, opts))
    thread
  end

  # Starts a thread and waits until its run has ended; returns the thread.
  defp ended!(project, text, opts \\ []) do
    thread = start!(project, text, opts)
    idle!(thread.id)
    thread
  end

  defp idle!(conversation_id) do
    :ok = Durable.subscribe(conversation_id)

    if Durable.busy?(conversation_id),
      do: await_change(conversation_id, fn _changes -> not Durable.busy?(conversation_id) end)

    :ok
  end

  # Blip's signal messages, oldest first, whatever their status.
  defp signals(blip) do
    query =
      from(s in Submission,
        where: s.conversation_id == ^blip,
        order_by: [asc: s.inserted_at, asc: s.id]
      )

    query |> Repo.all() |> Enum.filter(&(&1.content["source"]["kind"] == "signal"))
  end

  defp parts(%Submission{content: %{"parts" => parts}}), do: Enum.map(parts, & &1["text"])
  defp refs(%Submission{content: %{"source" => %{"signals" => refs}}}), do: refs

  # Parks Blip on a command that never finishes; returns its submission.
  defp park_blip!(blip) do
    fake_machine("box")
    {:ok, parked} = Assistant.send("on box: $ sleep 1000")
    assert Durable.busy?(blip)
    parked
  end

  # Stops Blip's parked run; the signals it kept then run.
  defp unpark_blip!(blip, parked) do
    :ok = Assistant.stop()
    assert %{status: "unanswered"} = await_settled(blip, parked.id)
  end

  describe "thread updates" do
    test "a thread Blip started that finishes posts an update into Blip's conversation", %{
      project: project,
      blip: blip
    } do
      thread = ended!(project, "files", source: @blip_source)

      assert [signal] = signals(blip)

      assert parts(signal) == [
               ~s{[Thread update] Garden / "files" (#{thread.id}) finished. } <>
                 "It said: This project has no context files yet."
             ]

      [first | _] = Repo.all(from(s in Submission, where: s.conversation_id == ^thread.id))

      assert [
               %{
                 "kind" => "thread_update",
                 "status" => "finished",
                 "key" => key,
                 "thread_id" => thread_id,
                 "title" => "files",
                 "project_id" => project_id,
                 "slug" => "garden",
                 "project" => "Garden"
               }
             ] = refs(signal)

      assert {key, thread_id, project_id} == {"settle:" <> first.id, thread.id, project.id}
      assert signal.request_id == "signal:" <> key

      # Blip was idle, so the update started a run, which answers it.
      assert %{status: "done"} = await_settled(blip, signal.id)
    end

    test "a thread Blip starts with start_thread posts an update when it finishes", %{
      project: project,
      blip: blip
    } do
      {:ok, asked} = Assistant.send("start thread in garden: files")
      assert %{status: "done"} = await_settled(blip, asked.id)
      assert [thread] = Threads.list(project.id)
      assert thread.started_by == "blip"
      idle!(thread.id)

      assert [signal] = signals(blip)
      assert [%{"status" => "finished", "thread_id" => thread_id}] = refs(signal)
      assert thread_id == thread.id
      assert [text] = parts(signal)
      assert text =~ ~s{[Thread update] Garden / "files" (#{thread.id}) finished.}
      assert %{status: "done"} = await_settled(blip, signal.id)
    end

    test "an owner's thread that finishes posts nothing", %{project: project, blip: blip} do
      _thread = ended!(project, "files")
      assert signals(blip) == []
    end

    test "an owner's thread that fails, or ends asking, posts", %{project: project, blip: blip} do
      failed = ended!(project, "fail: the pump is unplugged")
      asked = ended!(project, "ask me: which zone first")

      assert [failure, question] = signals(blip)
      assert [%{"status" => "failed", "thread_id" => failed_id}] = refs(failure)
      assert failed_id == failed.id
      assert [text] = parts(failure)

      assert text =~
               ~r/^\[Thread update\] Garden \/ ".*" \(#{failed.id}\) failed: .*the pump is unplugged$/

      assert [%{"status" => "asking", "thread_id" => asked_id}] = refs(question)
      assert asked_id == asked.id

      assert parts(question) == [
               ~s{[Thread update] Garden / "ask me: which zone first" (#{asked.id}) } <>
                 "is waiting on the user: which zone first?"
             ]

      idle!(blip)
    end

    test "a stopped run posts nothing, even Blip's", %{project: project, blip: blip} do
      fake_machine("box")
      thread = start!(project, "on box: $ sleep 1000", source: @blip_source)
      :ok = Threads.subscribe(thread.id)
      await_entry(thread.id, &(&1.kind == "assistant"))
      :ok = Threads.stop(thread.id)
      idle!(thread.id)
      assert signals(blip) == []
    end
  end

  describe "while Blip is busy" do
    test "two updates merge into one queued message, which one run answers, and Stop keeps it",
         %{project: project, blip: blip} do
      parked = park_blip!(blip)

      one = ended!(project, "files", source: @blip_source)
      two = ended!(project, "fail: no water", source: @blip_source)

      assert [carrier] = signals(blip)
      assert carrier.status == "queued"
      assert [first, second] = parts(carrier)
      assert first =~ "(#{one.id}) finished."
      assert second =~ "(#{two.id}) failed:"

      assert [%{"thread_id" => one_id, "status" => "finished"}, %{"thread_id" => two_id}] =
               refs(carrier)

      assert {one_id, two_id} == {one.id, two.id}

      # Blip's Stop withdraws what the owner typed and keeps the signals,
      # which then start the next run.
      unpark_blip!(blip, parked)
      assert %{status: "done"} = await_settled(blip, carrier.id)

      runs =
        Repo.all(
          from(t in TaskRecord, where: t.conversation_id == ^blip and t.kind == "generation")
        )

      assert length(runs) == 2
      assert Enum.count(runs, &(&1.checkpoint["submissions"] == [carrier.id])) == 1
    end
  end

  describe "questions" do
    # An `ask_blip` call in `thread` that waits and that nothing wakes, and
    # its question.
    defp ask!(thread, project, question) do
      task =
        Durable.create_task(%{
          kind: "test_ask",
          conversation_id: thread.id,
          waiting: %{"signal" => "never"}
        })

      {:ok, asked} =
        Questions.ask(%{
          task_id: task.id,
          thread_id: thread.id,
          thread_title: thread.title,
          project_id: project.id,
          project_slug: project.slug,
          project_name: project.name,
          question: question
        })

      asked
    end

    test "a question and an update while Blip is busy make two queued messages, never one", %{
      project: project,
      blip: blip
    } do
      parked = park_blip!(blip)
      owners = ended!(project, "files")

      first = ask!(owners, project, "Which zone first?")
      update = ended!(project, "files", source: @blip_source)
      second = ask!(owners, project, "Drip or spray?")

      assert [questions, updates] = signals(blip)
      assert {questions.status, updates.status} == {"queued", "queued"}
      assert first.submission_id == questions.id
      assert second.submission_id == questions.id

      assert Enum.map(refs(questions), &{&1["kind"], &1["question_id"]}) ==
               [{"question", first.id}, {"question", second.id}]

      assert parts(questions) == [
               ~s{[Question #{first.id} from Garden / "files" (#{owners.id})]\nWhich zone first?},
               ~s{[Question #{second.id} from Garden / "files" (#{owners.id})]\nDrip or spray?}
             ]

      assert [%{"kind" => "thread_update", "thread_id" => update_id}] = refs(updates)
      assert update_id == update.id

      # Each is placed on its own and answered before the next.
      unpark_blip!(blip, parked)
      assert %{status: "done", entry_id: question_entry} = await_settled(blip, questions.id)
      assert %{status: "done", entry_id: update_entry} = await_settled(blip, updates.id)

      kinds =
        blip
        |> Durable.entries()
        |> Enum.drop_while(&(&1.id != question_entry))
        |> Enum.map(&if(&1.id == update_entry, do: :update, else: &1.kind))

      assert ["user", "assistant" | _] = kinds
      assert :update in kinds
    end
  end

  describe "post_tx/2 and unpost_tx/2" do
    defp signal(key, text) do
      ref = %{"kind" => "thread_update", "key" => key, "status" => "finished"}
      %{key: key, text: text, ref: ref}
    end

    defp post!(signal), do: Durable.commit(&Signals.post_tx(&1, signal))
    defp unpost!(key), do: Durable.commit(&Signals.unpost_tx(&1, key))

    test "the same key twice makes one part, queued or placed", %{blip: blip} do
      parked = park_blip!(blip)

      carrier = post!(signal("k1", "one"))
      assert post!(signal("k1", "one again")).id == carrier.id
      assert post!(signal("k2", "two")).id == carrier.id
      assert post!(signal("k2", "two again")).id == carrier.id

      assert [carrier] = signals(blip)
      assert parts(carrier) == ["one", "two"]
      assert Enum.map(refs(carrier), & &1["key"]) == ["k1", "k2"]

      unpark_blip!(blip, parked)
      assert %{status: "done"} = await_settled(blip, carrier.id)

      # Placed now: a repeat makes nothing new.
      assert post!(signal("k1", "one more")).id == carrier.id
      assert length(signals(blip)) == 1
    end

    test "unpost_tx/2 drops one signal from a merged message, then withdraws it", %{
      blip: blip
    } do
      parked = park_blip!(blip)
      carrier = post!(signal("k1", "one"))
      assert post!(signal("k2", "two")).id == carrier.id

      assert unpost!("k1") == :ok
      assert [kept] = signals(blip)
      assert {kept.status, parts(kept)} == {"queued", ["two"]}
      assert Enum.map(refs(kept), & &1["key"]) == ["k2"]

      assert unpost!("k2") == :ok
      assert [%{status: "withdrawn"}] = signals(blip)
      assert unpost!("k_missing") == :ok

      unpark_blip!(blip, parked)
    end

    test "an older: stub goes in the source of the message it starts", %{blip: blip} do
      older = %{"text" => "[Digest delivered]", "drop_if_answer" => "[nothing to tell]"}
      ref = %{"kind" => "digest", "key" => "digest:t_1:0", "items" => [], "more" => 0}
      digest = post!(%{key: "digest:t_1:0", text: "[Digest] Since...", ref: ref, older: older})

      assert digest.content["source"] ==
               %{"kind" => "signal", "signals" => [ref], "older" => older}

      assert %{status: "done"} = await_settled(blip, digest.id)

      assert [user | _] = Durable.entries(blip)
      assert {user.kind, user.data["source"]["older"]} == {"user", older}

      update = post!(signal("k1", "one"))
      refute Map.has_key?(update.content["source"], "older")
      assert %{status: "done"} = await_settled(blip, update.id)
    end

    test "unpost_tx/2 leaves a placed signal alone", %{blip: blip} do
      placed = post!(signal("k1", "one"))
      assert placed.status == "placed"
      assert unpost!("k1") == :ok
      assert Repo.get!(Submission, placed.id).status in ["placed", "done"]
      assert %{status: "done"} = await_settled(blip, placed.id)
    end
  end

  describe "ambient mode" do
    defp ambient!(on?) do
      _doc = Durable.commit(&Signals.put_ambient_doc_tx(&1, %{"on" => on?}))
      :ok
    end

    defp items, do: Repo.all(from(i in DigestItem, order_by: [asc: i.inserted_at, asc: i.id]))

    defp collect!(item), do: Durable.commit(&Signals.collect_tx(&1, item))

    test "the mode is quiet until the doc says on, and follows it" do
      assert Signals.mode() == :quiet
      assert Signals.ambient_doc() == %{}
      ambient!(true)
      assert Signals.mode() == :ambient
      assert Durable.commit(&Signals.mode_tx/1) == :ambient
      assert Signals.ambient_doc() == %{"on" => true}
      ambient!(false)
      assert Signals.mode() == :quiet
    end

    test "an owner's thread that finishes makes one digest item and no signal", %{
      project: project,
      blip: blip
    } do
      ambient!(true)
      thread = ended!(project, "files")

      [first | _] = Repo.all(from(s in Submission, where: s.conversation_id == ^thread.id))

      assert [%DigestItem{kind: "finished", id: "di_" <> _} = item] = items()

      assert {item.key, item.thread_id, item.project_id} ==
               {"settle:" <> first.id, thread.id, project.id}

      assert item.note == "This project has no context files yet."
      assert signals(blip) == []
      assert Signals.pending() == [item]
      assert Durable.commit(&Signals.pending_tx/1) == [item]
    end

    test "a run that answers two queued inputs makes one item, at its end", %{project: project} do
      ambient!(true)
      :ok = Machines.register("box", %{"hostname" => "box", "capabilities" => ["ops:2"]})
      thread = start!(project, "on box: $ echo one", [])
      assert_receive {:push_op, op_id}, 5_000
      {:ok, second} = Threads.send(thread.id, "files")
      assert second.status == "queued"

      {[{"op.ack", _ack}], _routes} = Machines.snapshot("box", snapshot(op_id, "completed"), %{})
      idle!(thread.id)

      assert [%DigestItem{kind: "finished", key: key}] = items()
      assert key == "settle:" <> second.id
    end

    test "Blip's thread posts its update and makes no item; a failure posts and makes none", %{
      project: project,
      blip: blip
    } do
      ambient!(true)
      blips = ended!(project, "files", source: @blip_source)
      failed = ended!(project, "fail: the pump is unplugged")

      assert items() == []
      assert [one, two] = signals(blip)
      assert [%{"status" => "finished", "thread_id" => blips_id}] = refs(one)
      assert [%{"status" => "failed", "thread_id" => failed_id}] = refs(two)
      assert {blips_id, failed_id} == {blips.id, failed.id}
      idle!(blip)
    end

    test "with ambient mode off nothing is collected", %{project: project} do
      _thread = ended!(project, "files")
      assert collect!(%{key: "resolved:1", kind: "resolved", thread_id: "c_1"}) == :ok
      ambient!(false)
      _thread = ended!(project, "files")
      assert collect!(%{key: "resolved:2", kind: "resolved", thread_id: "c_1"}) == :ok
      assert items() == []
    end

    test "collect_tx/2 makes one row per key, announces each insert, and is total" do
      ambient!(true)
      :ok = Photon.Events.subscribe(Signals.ambient_topic())

      item = %{key: "file_written:1", kind: "file_written", project_id: "p_1", name: "notes.md"}
      assert collect!(Map.put(item, :writer, "user")) == :ok
      assert_receive {:ambient_changed}
      assert collect!(Map.put(item, :writer, "c_9")) == :ok
      refute_receive {:ambient_changed}, 50

      assert [%DigestItem{writer: "user", name: "notes.md", thread_id: nil, note: nil}] = items()

      # Junk collects nothing and never raises; a long note is cut.
      for junk <- [nil, "x", %{}, %{key: "k", kind: "nope"}, %{key: nil, kind: "resolved"}],
          do: assert(collect!(junk) == :ok)

      long = String.duplicate("a", 700)

      assert collect!(%{key: "s:1", kind: "schedule_stopped", schedule_id: 5, note: long}) ==
               :ok

      assert [_file, %DigestItem{kind: "schedule_stopped", schedule_id: nil, note: note}] =
               items()

      assert String.length(note) == 600
    end

    test "drop_items_tx/2 deletes the given items, or all" do
      ambient!(true)
      for n <- 1..3, do: collect!(%{key: "resolved:#{n}", kind: "resolved", thread_id: "c_#{n}"})
      [one, _two, three] = items()

      assert Durable.commit(&Signals.drop_items_tx(&1, [one.id, three.id])) == :ok
      assert [%DigestItem{thread_id: "c_2"}] = items()
      assert Durable.commit(&Signals.drop_items_tx(&1, [])) == :ok
      assert Durable.commit(&Signals.drop_items_tx(&1, :all)) == :ok
      assert items() == []
    end

    test "withdraw_ambient_tx/1 withdraws a queued digest, returns its ref and leaves an update",
         %{blip: blip} do
      parked = park_blip!(blip)
      refute Durable.commit(&Signals.queued_ambient?(&1, "digest"))

      ref = %{"kind" => "digest", "key" => "digest:t_1:0", "items" => [], "more" => 0}
      digest = post!(%{key: "digest:t_1:0", text: "[Digest] Since...", ref: ref})
      update = post!(signal("k1", "one"))
      assert {digest.status, update.status} == {"queued", "queued"}
      refute digest.id == update.id

      assert Durable.commit(&Signals.queued_ambient?(&1, "digest"))
      refute Durable.commit(&Signals.queued_ambient?(&1, "review"))

      assert Durable.commit(&Signals.withdraw_ambient_tx/1) == [ref]
      assert Repo.get!(Submission, digest.id).status == "withdrawn"
      assert Repo.get!(Submission, update.id).status == "queued"
      refute Durable.commit(&Signals.queued_ambient?(&1, "digest"))
      assert Durable.commit(&Signals.withdraw_ambient_tx/1) == []

      unpark_blip!(blip, parked)
      assert %{status: "done"} = await_settled(blip, update.id)
    end
  end

  describe "schedules" do
    defp schedule!(project, id, created_by) do
      Repo.insert!(%Schedule{
        id: id,
        project_id: project.id,
        prompt: "files",
        first_at: DateTime.utc_now(),
        version: 1,
        created_by: created_by
      })
    end

    test "a thread a Blip-made project schedule starts posts an update when it finishes", %{
      project: project,
      blip: blip
    } do
      schedule = schedule!(project, "sc_blip", "blip")
      assert Schedules.run_now(schedule.id) == {:ok, "started"}
      [thread] = Threads.list(project.id)
      idle!(thread.id)

      assert [signal] = signals(blip)
      assert [%{"status" => "finished", "thread_id" => thread_id}] = refs(signal)
      assert thread_id == thread.id
      assert Threads.get(thread.id).started_by == "schedule"
      assert %{status: "done"} = await_settled(blip, signal.id)
    end

    test "a thread a project schedule from Blip's schedule tool starts posts an update", %{
      project: project,
      blip: blip
    } do
      :ok = Schedules.subscribe()
      project_id = project.id
      {:ok, asked} = Assistant.send("in 0 minutes in garden: files")
      await_settled(blip, asked.id)

      # Made, then fired at once.
      assert_receive {:schedules_changed, ^project_id}
      assert_receive {:schedules_changed, ^project_id}, 5_000

      assert [%{schedule: %Schedule{created_by: "blip", asked_by: "owner"} = schedule}] =
               Schedules.list({:project, project.id})

      assert %Schedule{last_outcome: "started", last_thread_id: thread_id} =
               Repo.get!(Schedule, schedule.id)

      idle!(thread_id)

      assert [signal] = signals(blip)
      assert [%{"status" => "finished", "thread_id" => ^thread_id}] = refs(signal)
      assert Threads.get(thread_id).started_by == "schedule"
      assert %{status: "done"} = await_settled(blip, signal.id)
    end

    test "one the owner's schedule starts posts nothing", %{project: project, blip: blip} do
      schedule = schedule!(project, "sc_owner", "owner")
      assert Schedules.run_now(schedule.id) == {:ok, "started"}
      [thread] = Threads.list(project.id)
      idle!(thread.id)
      assert signals(blip) == []
    end
  end
end
