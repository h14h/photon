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

  alias Photon.{Assistant, Projects, Questions, Schedules, Signals, Threads}
  alias Photon.Durable.{Submission, TaskRecord}
  alias Photon.Schedules.Schedule

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

    test "unpost_tx/2 leaves a placed signal alone", %{blip: blip} do
      placed = post!(signal("k1", "one"))
      assert placed.status == "placed"
      assert unpost!("k1") == :ok
      assert Repo.get!(Submission, placed.id).status in ["placed", "done"]
      assert %{status: "done"} = await_settled(blip, placed.id)
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

    test "one the owner's schedule starts posts nothing", %{project: project, blip: blip} do
      schedule = schedule!(project, "sc_owner", "owner")
      assert Schedules.run_now(schedule.id) == {:ok, "started"}
      [thread] = Threads.list(project.id)
      idle!(thread.id)
      assert signals(blip) == []
    end
  end
end
