defmodule Photon.DurableHooksTest do
  @moduledoc """
  The profile hooks (`on_settled/3`, `on_tool_result/4`) through the
  harness, with `Photon.TestProfile.Hooks`, which announces each call on
  `"test:hooks"` from inside the commit it ran in. A message therefore
  means the hook ran in a commit that was stored; counting them shows it
  ran once.
  """

  use Photon.DataCase, async: false

  alias Photon.Durable.{Scheduler, Submission, Tx}
  alias Photon.TestProfile.Hooks

  @moduletag :durable

  setup do
    Photon.Events.subscribe(Hooks.topic())
    c = Durable.create_conversation("test_hooks").id
    Durable.subscribe(c)
    %{conversation: c}
  end

  defp await_tool_waiting(c) do
    await_change(c, &Enum.any?(&1.tasks, fn t -> t.kind == "tool" and t.status == "waiting" end))
  end

  # Every hook message for `c` received so far, once the scheduler has
  # nothing left to start, in order.
  defp hooks(c, kind) do
    :ok = Scheduler.sync()
    drain(c, kind, [])
  end

  defp drain(c, kind, acc) do
    receive do
      {^kind, ^c, payload} -> drain(c, kind, [payload | acc])
      {^kind, ^c, task, entry} -> drain(c, kind, [{task, entry} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp ids(submissions), do: Enum.map(submissions, & &1.id)

  defp answer_entry_id(c) do
    [answer] = Durable.last_entries(c, "assistant", 1)
    answer.id
  end

  # A user input placed by hand, as a run's would be.
  defp placed(tx, c, text) do
    submission =
      Tx.insert_submission(tx, %{
        conversation_id: c,
        mode: "follow_up",
        content: %{"parts" => [PhotonCore.Message.text(text)]},
        status: "queued"
      })

    Durable.place(tx, submission)
  end

  describe "on_settled/3" do
    test "runs once when a run answers, with the answer and what it closed", %{
      conversation: c
    } do
      {:ok, s} = Durable.submit(c, "hello")
      await_settled(c, s.id)

      assert [settled] = hooks(c, :settled)
      assert %{outcome: "done", reason: nil, ended?: true} = settled
      assert settled.answer_entry_id == answer_entry_id(c)
      assert [%Submission{status: "done"}] = settled.submissions
      assert ids(settled.submissions) == [s.id]
      assert settled.task.kind == "generation"
    end

    test "with input queued, the first settle doesn't end the run and the next one does", %{
      conversation: c
    } do
      {:ok, first} = Durable.submit(c, "wait")
      await_tool_waiting(c)
      {:ok, second} = Durable.submit(c, "later")

      Durable.signal("go")
      await_settled(c, second.id)

      assert [one, two] = hooks(c, :settled)
      assert %{outcome: "done", ended?: false} = one
      assert ids(one.submissions) == [first.id]
      assert %{outcome: "done", ended?: true} = two
      assert ids(two.submissions) == [second.id]
      assert one.task.id == two.task.id
      assert two.answer_entry_id == answer_entry_id(c)
    end

    test "a model error settles as failed, with the error", %{conversation: c} do
      {:ok, s} = Durable.submit(c, "fail")
      await_settled(c, s.id)

      assert [settled] = hooks(c, :settled)
      assert %{outcome: "failed", answer_entry_id: nil, ended?: true} = settled
      assert settled.reason =~ "model down"
      assert [%Submission{status: "unanswered"}] = settled.submissions
    end

    test "the round limit settles as failed", %{conversation: c} do
      # A run on its last allowed round, whose answer asks for a tool.
      s =
        Durable.commit(fn tx ->
          s = placed(tx, c, "commit")

          _task =
            Tx.create_task(tx, %{
              kind: "generation",
              conversation_id: c,
              phase: "request",
              checkpoint: %{"submissions" => [s.id], "rounds" => Durable.Turn.max_rounds() - 1}
            })

          s
        end)

      await_settled(c, s.id)

      assert [settled] = hooks(c, :settled)
      assert %{outcome: "failed", reason: "too many tool rounds", ended?: true} = settled
      assert ids(settled.submissions) == [s.id]
      # The calls past the limit weren't run, so no tool task recorded them.
      assert hooks(c, :tool_result) == []
    end

    test "a Stop settles as stopped", %{conversation: c} do
      {:ok, s} = Durable.submit(c, "wait")
      await_tool_waiting(c)

      Durable.abort(c)
      await_settled(c, s.id)

      assert [settled] = hooks(c, :settled)
      assert %{outcome: "stopped", reason: "stopped", ended?: true} = settled
      assert [%Submission{status: "unanswered"}] = settled.submissions
      assert ids(settled.submissions) == [s.id]
    end

    # The crash is logged.
    @tag :capture_log
    test "a failed task settles as failed, and the Scheduler carries on", %{conversation: c} do
      scheduler = Process.whereis(Scheduler)
      {:ok, s} = Durable.submit(c, "crash")
      await_settled(c, s.id)

      assert [settled] = hooks(c, :settled)
      assert %{outcome: "failed", ended?: true, answer_entry_id: nil} = settled
      assert settled.reason =~ "the model crashed"
      assert ids(settled.submissions) == [s.id]
      assert Process.whereis(Scheduler) == scheduler
    end

    test "a settle that closes nothing still runs, with no submissions", %{conversation: c} do
      # A run whose input was settled before it answered.
      Durable.commit(fn tx ->
        s = placed(tx, c, "hello")
        _done = Tx.update_submission(tx, s, status: "done")

        Tx.create_task(tx, %{
          kind: "generation",
          conversation_id: c,
          phase: "request",
          checkpoint: %{"submissions" => [s.id]}
        })
      end)

      await_entry(c, &(&1.kind == "assistant"))

      assert [%{outcome: "done", submissions: [], ended?: true}] = hooks(c, :settled)
    end

    test "a profile without the hooks runs as before" do
      c = Durable.create_conversation("test").id
      Durable.subscribe(c)
      {:ok, s} = Durable.submit(c, "wait")
      await_tool_waiting(c)
      Durable.signal("go")

      assert %{status: "done"} = await_settled(c, s.id)
      assert hooks(c, :settled) == []
      assert hooks(c, :tool_result) == []
    end
  end

  describe "on_tool_result/4" do
    # One result, from the tool task that recorded it, as stored.
    defp one_result(c) do
      assert [{task, entry}] = hooks(c, :tool_result)
      assert task.kind == "tool"
      assert entry.kind == "tool_result"
      stored = Durable.entry(c, entry.id)
      assert {stored.kind, stored.data} == {entry.kind, entry.data}
      entry.data
    end

    test "runs once for a tool's result", %{conversation: c} do
      {:ok, s} = Durable.submit(c, "wait")
      await_tool_waiting(c)
      Durable.signal("go")
      await_settled(c, s.id)

      assert %{"status" => "ok", "name" => "wait"} = one_result(c)
    end

    test "runs once for a {:commit, fun} result", %{conversation: c} do
      {:ok, s} = Durable.submit(c, "commit")
      await_settled(c, s.id)

      assert %{"status" => "ok", "name" => "commit"} = one_result(c)
    end

    # The raise is logged.
    @tag :capture_log
    test "runs once for a tool that raises", %{conversation: c} do
      {:ok, s} = Durable.submit(c, "raise")
      await_settled(c, s.id)

      assert %{"status" => "error", "name" => "raise"} = one_result(c)
    end

    test "runs once for a call that is stopped", %{conversation: c} do
      {:ok, s} = Durable.submit(c, "wait")
      await_tool_waiting(c)
      Durable.abort(c)
      await_settled(c, s.id)

      assert %{"status" => "aborted", "name" => "wait"} = one_result(c)
    end

    # The exit is logged.
    @tag :capture_log
    test "runs once for a call whose task fails", %{conversation: c} do
      {:ok, s} = Durable.submit(c, "exit")
      await_settled(c, s.id)

      assert %{"status" => "error", "name" => "exit"} = one_result(c)
    end
  end
end
