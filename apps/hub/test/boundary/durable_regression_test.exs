defmodule Photon.DurableRegressionTest do
  @moduledoc """
  Regression tests for the durable harness, each named after the
  verification finding it pins (the Durable F-numbers are written up in
  `specs/tla/Durable.md`).
  """

  use Photon.DataCase, async: false

  import Ecto.Query
  import Photon.ConversationHelpers

  alias Photon.Durable.{Entry, Scheduler, Submission, TaskRecord}
  alias PhotonCore.Message

  @moduletag :durable

  setup do
    Photon.HarnessProfiles.use_profiles()
    :ok
  end

  defp conversation(profile) do
    c = Durable.create_conversation(profile).id
    Durable.subscribe(c)
    c
  end

  defp status(submission), do: Repo.get(Submission, submission.id).status

  defp restart_scheduler_and_store do
    stop_supervised!(Photon.Durable.Scheduler)
    stop_supervised!(Photon.Durable.Store)
    start_supervised!(Photon.Durable.Store)
    start_supervised!(Photon.Durable.Scheduler)
  end

  describe "input queued behind a run that ends without answering (Durable F4)" do
    # Durable F4: input queued behind a run that ended without an answer
    # stayed queued forever on an idle conversation.
    test "input queued behind a run whose model request fails still gets answered" do
      c = conversation("test")
      {:ok, first} = Durable.submit(c, "wait")
      await_tool_waiting(c)
      {:ok, failing} = Durable.submit(c, "fail")
      {:ok, later} = Durable.submit(c, "hi")

      Durable.signal("go")
      await_settled(c, first.id)
      assert %{status: "done"} = await_settled(c, later.id)
      assert status(failing) == "unanswered"
      assert "echo: hi" in texts(c, "assistant")
    end

    # hub-abort-strands-submission (Durable F4, Stop variant): a submission
    # made after Stop but before the run was aborted stayed queued forever.
    test "input sent while a stopped run is still being aborted starts the next run" do
      c = conversation("test")
      {:ok, first} = Durable.submit(c, "wait")
      await_tool_waiting(c)

      stop_supervised!(Photon.Durable.Scheduler)
      Durable.abort(c)
      {:ok, later} = Durable.submit(c, "hi")
      assert later.status == "queued"
      start_supervised!(Photon.Durable.Scheduler)

      assert %{status: "unanswered"} = await_settled(c, first.id)
      assert %{status: "done"} = await_settled(c, later.id)
    end
  end

  describe "stops and limits" do
    # Durable F7: a run marked for abort whose step returned before the
    # scheduler killed it ended "failed" (on_fail) instead of "aborted".
    test "a run stopped while its step is finishing ends aborted, not failed" do
      c = conversation("block")
      {:ok, s} = Durable.submit(c, "block")
      assert_receive {:model_request, model}, 5_000
      [step] = Task.Supervisor.children(Photon.Durable.TaskSupervisor)

      scheduler = Process.whereis(Scheduler)
      :sys.suspend(scheduler)
      Durable.abort(c)
      ref = Process.monitor(step)
      send(model, :release)
      assert_receive {:DOWN, ^ref, :process, ^step, _}, 5_000
      :sys.resume(scheduler)

      assert %{status: "unanswered", reason: "stopped"} = await_settled(c, s.id)

      assert [%TaskRecord{status: "aborted"}] =
               Repo.all(
                 from(t in TaskRecord, where: t.conversation_id == ^c and t.kind == "generation")
               )

      assert Enum.any?(Durable.entries(c), &(&1.kind == "error" and &1.data["stopped"]))
    end

    # Durable F8: when a run hit the round limit, the calls in its last
    # assistant entry never got a tool_result.
    test "a run that hits the round limit gives every stored call a result" do
      c = conversation("loop")
      Durable.signal("go")
      {:ok, s} = Durable.submit(c, "go on", request_id: "loop")

      assert %{status: "unanswered", reason: "too many tool rounds"} =
               await_settled(c, s.id, 60_000)

      entries = Durable.entries(c)

      calls =
        for %Entry{kind: "assistant"} = e <- entries,
            call <- Message.tool_calls(e.data["message"]),
            do: call["id"]

      results =
        for %Entry{kind: "tool_result"} = e <- entries, do: e.data["message"]["tool_call_id"]

      assert length(calls) == 60
      assert Enum.sort(results) == Enum.sort(calls)
    end
  end

  describe "a scheduler restart (Durable F10)" do
    # Durable F10 / hub-scheduler-restart-duplicates-steps: a step still
    # running from before a scheduler restart committed on top of the rerun.
    test "a step left over from a scheduler restart can't commit" do
      c = conversation("block")
      {:ok, s} = Durable.submit(c, "block wait")
      assert_receive {:model_request, old_step}, 5_000

      restart_scheduler_and_store()
      assert_receive {:model_request, new_step}, 5_000

      send(old_step, :release)
      ref = Process.monitor(old_step)
      assert_receive {:DOWN, ^ref, :process, ^old_step, _}, 5_000
      send(new_step, :release)
      await_tool_waiting(c)
      Durable.signal("go")
      assert %{status: "done"} = await_settled(c, s.id)

      assert entry_kinds(c) == ["user", "assistant", "tool_result", "assistant"]
      assert Repo.aggregate(from(t in TaskRecord, where: t.kind == "tool"), :count) == 1
    end

    # Found while modeling the fix above: fencing on `runs` alone isn't
    # enough, since `runs` restarts with each phase. A step left over from
    # the first "request" could match the run count of a later "request" of
    # the same task and commit into it.
    test "a leftover step can't commit into a later run of its phase" do
      c = conversation("block")
      {:ok, s} = Durable.submit(c, "block wait block")
      assert_receive {:model_request, old_step}, 5_000

      restart_scheduler_and_store()
      assert_receive {:model_request, rerun}, 5_000
      send(rerun, :release)
      await_tool_waiting(c)
      Durable.signal("go")

      # The generation is back in "request" (its first start of that phase
      # again) when the leftover step commits its tool call.
      assert_receive {:model_request, second_request}, 5_000
      ref = Process.monitor(old_step)
      send(old_step, :release)
      assert_receive {:DOWN, ^ref, :process, ^old_step, _}, 5_000
      send(second_request, :release)

      assert %{status: "done"} = await_settled(c, s.id)
      assert entry_kinds(c) == ["user", "assistant", "tool_result", "assistant"]
      assert List.last(texts(c, "assistant")) == "released"
    end
  end

  describe "a task kind's module" do
    # hub-function-exported-unloaded: on_abort/on_fail were looked up with
    # function_exported?/3, false for a module that isn't loaded yet.
    test "a run aborted before its task module is loaded still settles its input" do
      stop_supervised!(Photon.Durable.Scheduler)
      c = conversation("test")
      {:ok, s} = Durable.submit(c, "hi")
      Durable.abort(c)

      :code.purge(Photon.Durable.Generation)
      :code.delete(Photon.Durable.Generation)
      on_exit(fn -> Code.ensure_loaded!(Photon.Durable.Generation) end)
      start_supervised!(Photon.Durable.Scheduler)

      assert %{status: "unanswered"} = await_settled(c, s.id)
      assert "error" in entry_kinds(c)
    end
  end
end
