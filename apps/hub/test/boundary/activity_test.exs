defmodule Photon.ActivityTest do
  @moduledoc """
  The activity log (section 6 of `docs/plans/step-4-blip-as-coordinator.md`)
  through Blip's hooks on the durable harness, driven by the scripted
  Blip: each tool call's row with who asked, the message rows of runs the
  owner didn't type into, the rows on the Stop path, and `list/1`. The
  summaries themselves are covered in `test/core/activity/rules_test.exs`.
  """

  use Photon.DataCase, async: false

  @moduletag :durable

  alias Photon.{Activity, Assistant, Projects, Questions, Schedules, Signals, Threads}
  alias Photon.Activity.Action
  alias Photon.Durable.{Entry, Scheduler, TaskRecord}
  alias Photon.Questions.Question

  setup do
    {:ok, garden} =
      Projects.create(%{"purpose" => "Keep the vegetable beds watered.", "name" => "Garden"})

    blip = Assistant.conversation_id()
    :ok = Durable.subscribe(blip)
    :ok = Activity.subscribe()
    %{garden: garden, blip: blip}
  end

  defp idle!(conversation_id) do
    :ok = Durable.subscribe(conversation_id)

    if Durable.busy?(conversation_id),
      do: await_change(conversation_id, fn _changes -> not Durable.busy?(conversation_id) end)

    :ok
  end

  # The first row `fun` holds for, already recorded or still to come.
  defp await_row!(fun) do
    {rows, _more?} = Activity.list(limit: 500)

    case Enum.find(rows, fun) do
      nil ->
        assert_receive {:activity_added, _id}, 5_000
        await_row!(fun)

      row ->
        row
    end
  end

  defp rows do
    {rows, _more?} = Activity.list(limit: 500)
    rows
  end

  defp entry!(blip, id), do: %Entry{} = Durable.entry(blip, id)

  # Posts a signal into Blip's conversation whose text is one of the
  # scripted Blip's phrasings, as a thread's update would arrive, so the
  # run it starts calls that tool on Blip's own follow-up.
  defp post_update!(text, thread_id) do
    key = "test:#{System.unique_integer([:positive])}"

    ref = %{
      "kind" => "thread_update",
      "status" => "finished",
      "key" => key,
      "thread_id" => thread_id
    }

    Durable.commit(&Signals.post_tx(&1, %{key: key, text: text, ref: ref}))
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

  # Parks Blip on a command that never finishes, on `box`, a machine the
  # test process plays: its shell call is under way once this returns.
  defp park_blip!(blip) do
    fake_machine("box")
    {:ok, _parked} = Assistant.send("on box: $ sleep 1000")
    _call = await_entry(blip, &(&1.kind == "assistant"))
    assert Durable.busy?(blip)
    :ok
  end

  describe "a tool call's row" do
    test "a call for the owner says what Blip did, where, and that the owner asked", %{
      garden: garden,
      blip: blip
    } do
      {:ok, s} = Assistant.send("start thread in garden: files")
      await_settled(blip, s.id)

      row = await_row!(&(&1.tool == "start_thread"))
      thread = Threads.get(row.thread_id)

      assert %Action{
               kind: "call",
               status: "ok",
               changes: true,
               origin: "owner",
               origin_id: nil,
               project_id: project_id
             } = row

      assert project_id == garden.id
      assert row.summary == ~s(Started "#{thread.title}" in garden)
      assert %Entry{kind: "tool_result"} = entry!(blip, row.entry_id)
      row_id = row.id
      assert_receive {:activity_added, ^row_id}
      assert Activity.get(row.id) == row

      # The thread Blip started finishes, Blip hears of it and tells the
      # owner without a tool: a message row, on Blip's follow-up.
      :ok = idle!(thread.id)
      message = await_row!(&(&1.kind == "message"))
      :ok = idle!(blip)

      assert %Action{
               tool: nil,
               status: "ok",
               changes: false,
               origin: "follow_up",
               project_id: nil,
               thread_id: nil
             } = message

      assert message.origin_id == thread.id
      assert message.summary == "Told you: #{thread.title} in Garden finished."
      assert %Entry{kind: "assistant"} = entry!(blip, message.entry_id)

      # The run the owner typed into made no message row.
      assert [_one] = Enum.filter(rows(), &(&1.kind == "message"))
    end

    test "a call in a run a thread update started is Blip's follow-up, never the thread's", %{
      blip: blip
    } do
      :ok = idle!(blip)
      signal = post_update!("projects", "c_watched")
      await_settled(blip, signal.id)

      row = await_row!(&(&1.tool == "list_projects"))

      assert %Action{origin: "follow_up", origin_id: "c_watched", changes: false} = row
      assert row.summary == "Listed projects"
      refute Enum.any?(rows(), &(&1.origin == "thread"))
    end

    test "a firing of Blip's schedule: the owner's is a schedule, its own a follow-up", %{
      blip: blip
    } do
      cases = [
        {%{"prompt" => "projects", "in_minutes" => 60}, "owner", "schedule"},
        {%{"prompt" => "projects", "every_minutes" => 60}, "owner", "schedule"},
        {%{"prompt" => "projects", "in_minutes" => 60}, "blip", "follow_up"},
        {%{"prompt" => "projects", "every_minutes" => 60}, "blip", "follow_up"}
      ]

      for {{args, asked_by, origin}, n} <- Enum.with_index(cases) do
        made = %{
          asked_by: asked_by,
          request_id: "test:#{n}",
          now: System.system_time(:millisecond)
        }

        {:ok, schedule} =
          Durable.commit(&Schedules.tool_schedule_tx(&1, {:blip, blip}, args, made))

        :ok = idle!(blip)
        assert Schedules.run_now(schedule.id) == {:ok, "sent"}

        call = await_row!(&(&1.tool == "list_projects" and &1.origin_id == schedule.id))
        assert call.origin == origin, "#{inspect(args)} asked by #{asked_by}"

        # Blip's reply in a run a schedule started is a message row too.
        message = await_row!(&(&1.kind == "message" and &1.origin_id == schedule.id))
        assert message.origin == origin
        :ok = idle!(blip)
      end
    end

    test "a call stopped while it runs records aborted", %{blip: blip} do
      :ok = park_blip!(blip)
      :ok = Assistant.stop()

      row = await_row!(&(&1.tool == "shell"))
      :ok = idle!(blip)

      assert %Action{status: "aborted", origin: "owner", changes: true} = row
      assert row.summary == "Ran `sleep 1000` on box: stopped"
    end

    test "a call whose arguments don't decode, stopped before it runs, says Used and the Scheduler lives",
         %{blip: blip} do
      :ok = stop_supervised!(Scheduler)

      task =
        Durable.create_task(%{
          kind: "tool",
          conversation_id: blip,
          input: %{"call" => %{"id" => "call_bad", "name" => "shell", "arguments" => "{\"mach"}},
          waiting: %{"signal" => "never"}
        })

      %TaskRecord{abort_requested: true} = Durable.abort_task(task.id)
      scheduler = start_supervised!(Scheduler)

      row = await_row!(&(&1.tool == "shell"))

      assert %Action{
               summary: "Used shell: stopped",
               status: "aborted",
               origin: "unknown",
               origin_id: nil,
               project_id: nil,
               thread_id: nil
             } = row

      assert Durable.task(task.id).status == "aborted"
      _state = :sys.get_state(scheduler)
      assert Process.whereis(Scheduler) == scheduler
    end
  end

  describe "questions" do
    test "answer_question and ask_owner in a run of two questions are each their thread's", %{
      garden: garden,
      blip: blip
    } do
      :ok = Assistant.put_memory("- deploy branch: staging")
      :ok = Questions.subscribe()

      # Both questions arrive while Blip is busy, so one message carries
      # them, and Blip's run on it answers one and asks the owner the other.
      :ok = park_blip!(blip)
      {:ok, first} = Threads.start(garden.id, "ask blip: which deploy branch should I use?")
      {:ok, second} = Threads.start(garden.id, "ask blip: is the gate locked?")
      asked!(first)
      asked!(second)
      :ok = Assistant.stop()

      answered = await_row!(&(&1.tool == "answer_question"))
      passed = await_row!(&(&1.tool == "ask_owner"))

      assert {answered.origin, answered.origin_id, answered.thread_id} ==
               {"thread", first.id, first.id}

      assert {passed.origin, passed.origin_id, passed.thread_id} ==
               {"thread", second.id, second.id}

      assert answered.summary == ~s(Answered "#{Threads.get(first.id).title}"'s question)
      assert passed.summary =~ ~r/\AAsked you: /

      # The owner answers; Blip's run on their answer is the owner's, so
      # its reply makes no message row.
      [%Question{} = open] = Questions.open()
      assert {:ok, _answered} = Questions.answer(open.id, "yes")
      :ok = idle!(first.id)
      :ok = idle!(second.id)
      :ok = idle!(blip)

      refute Enum.any?(rows(), &(&1.kind == "message" and &1.origin == "owner"))

      # The parked call the stop ended is the owner's; the only calls a
      # thread asked for are the two that handled its own question.
      assert %Action{origin: "owner", status: "aborted"} = await_row!(&(&1.tool == "shell"))
      thread_calls = for %Action{kind: "call", origin: "thread", tool: tool} <- rows(), do: tool
      assert Enum.sort(thread_calls) == ["answer_question", "ask_owner"]
    end

    defp asked!(thread) do
      thread_id = thread.id

      case Questions.open_by_thread([thread_id]) do
        %{^thread_id => [_asked]} ->
          :ok

        _not_yet ->
          assert_receive {:questions_changed, ^thread_id}, 5_000
          asked!(thread)
      end
    end
  end

  describe "record_tx/2" do
    defp record(entry_id, call, origin \\ %{by: "owner", id: nil}) do
      %{
        kind: "call",
        task: %TaskRecord{input: %{"call" => call}},
        entry: %Entry{id: entry_id, data: %{"status" => "ok", "details" => %{}}},
        origin: origin
      }
    end

    test "records an entry once" do
      call = %{"name" => "list_projects", "arguments" => "{}"}
      assert Durable.commit(&Activity.record_tx(&1, record("e_1", call))) == :ok
      assert_receive {:activity_added, id}
      assert Durable.commit(&Activity.record_tx(&1, record("e_1", call))) == :ok
      refute_receive {:activity_added, _id}, 50

      assert [%Action{id: ^id, summary: "Listed projects", entry_id: "e_1"}] = rows()
    end

    test "is total: garbage records less, never raises" do
      assert Durable.commit(&Activity.record_tx(&1, %{kind: "call"})) == :ok
      assert Durable.commit(&Activity.record_tx(&1, :nonsense)) == :ok
      assert Durable.commit(&Activity.record_tx(&1, %{kind: "message", entry_id: nil})) == :ok
      assert rows() == []

      bare = %{kind: "call", task: nil, entry: %Entry{id: "e_2", data: nil}, origin: :garbage}
      assert Durable.commit(&Activity.record_tx(&1, bare)) == :ok

      message = %{kind: "message", entry_id: "e_3", text: nil, origin: %{by: "comet", id: 5}}
      assert Durable.commit(&Activity.record_tx(&1, message)) == :ok

      assert [
               %Action{entry_id: "e_3", summary: "Told you something", origin: "unknown"},
               %Action{
                 entry_id: "e_2",
                 summary: "Used a tool: failed",
                 status: "error",
                 origin: "unknown",
                 origin_id: nil
               }
             ] = rows()
    end
  end

  describe "list/1" do
    defp row!(id, at, fields) do
      Repo.insert!(
        struct!(
          %Action{
            id: id,
            kind: "call",
            tool: "shell",
            summary: "Ran `ls` on mm1",
            status: "ok",
            changes: true,
            origin: "owner",
            entry_id: "e_" <> id,
            inserted_at: DateTime.add(~U[2026-10-06 12:00:00.000000Z], at, :second)
          },
          fields
        )
      )
    end

    setup do
      rows = [
        row!("a_1", 1, tool: "list_projects", changes: false),
        row!("a_2", 2, origin: "thread", origin_id: "c_1"),
        row!("a_3", 3, origin: "schedule", origin_id: "sc_1", changes: false),
        # Two rows at the same time, ordered by ID.
        row!("a_4", 4, []),
        row!("a_5", 4, origin: "follow_up")
      ]

      %{rows: rows}
    end

    defp ids({rows, more?}), do: {Enum.map(rows, & &1.id), more?}

    test "newest first, with whether there are more past the limit" do
      assert ids(Activity.list()) == {~w(a_5 a_4 a_3 a_2 a_1), false}
      assert ids(Activity.list(limit: 2)) == {~w(a_5 a_4), true}
      assert ids(Activity.list(limit: 5)) == {~w(a_5 a_4 a_3 a_2 a_1), false}
    end

    test "before a row goes on past it, including a row at the same time", %{rows: rows} do
      a_5 = List.last(rows)
      assert ids(Activity.list(limit: 2, before: a_5)) == {~w(a_4 a_3), true}

      {[_a_4, a_3], true} = Activity.list(limit: 2, before: a_5)

      assert ids(Activity.list(limit: 2, before: {a_3.inserted_at, a_3.id})) ==
               {~w(a_2 a_1), false}
    end

    test "by who asked, and changes only" do
      assert ids(Activity.list(origin: "owner")) == {~w(a_4 a_1), false}
      assert ids(Activity.list(origin: "thread")) == {~w(a_2), false}
      assert ids(Activity.list(origin: "follow_up")) == {~w(a_5), false}
      assert ids(Activity.list(changes_only: true)) == {~w(a_5 a_4 a_2), false}
      assert ids(Activity.list(origin: "owner", changes_only: true)) == {~w(a_4), false}
      # An origin the log doesn't know filters nothing.
      assert ids(Activity.list(origin: "comet")) == {~w(a_5 a_4 a_3 a_2 a_1), false}
    end

    test "get/1" do
      assert %Action{id: "a_2", origin_id: "c_1"} = Activity.get("a_2")
      assert Activity.get("a_none") == nil
      assert Activity.get(nil) == nil
    end
  end
end
