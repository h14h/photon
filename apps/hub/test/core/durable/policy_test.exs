defmodule Photon.Durable.PolicyTest do
  @moduledoc """
  The scheduler's rules, on plain task records: what it stops, wakes,
  starts and fails, and when it looks again.
  """

  use Photon.Case, async: true

  defp facts(statuses \\ nil, signal? \\ nil), do: %{statuses: statuses, signal?: signal?}

  describe "stopping" do
    test "kills only the steps this scheduler runs, for tasks marked for abort" do
      aborting = [task(id: "a", abort_requested: true), task(id: "b", abort_requested: true)]

      assert Policy.steps_to_kill(aborting, %{"a" => :step_a, "c" => :step_c}) ==
               [{"a", :step_a}]
    end

    test "picks out the tasks marked for abort" do
      marked = task(id: "a", abort_requested: true)
      assert Policy.aborting([marked, task(id: "b")]) == [marked]
    end

    test "aborts bottom-up: a task waits while foreground work it owns is unfinished" do
      parent = task(id: "p", abort_requested: true)
      child = task(id: "c", kind: "tool", owner_task_id: "p", abort_requested: true)

      assert Policy.ready_to_abort([parent, child]) == [child]
      assert Policy.ready_to_abort([parent]) == [parent]
    end

    test "background work doesn't hold up its owner's abort" do
      parent = task(id: "p", abort_requested: true)
      background = task(id: "w", kind: "routine", owner_task_id: "p", background: true)

      assert Policy.ready_to_abort([parent, background]) == [parent]
    end

    test "only an unfinished task is aborted, and the abort records its outcome" do
      assert Policy.abort?(task(status: "waiting"))
      refute Policy.abort?(task(status: "done"))
      refute Policy.abort?(task(status: "aborted"))
      refute Policy.abort?(nil)

      assert Policy.aborted() == [
               status: "aborted",
               outcome: %{"status" => "aborted"},
               waiting: nil
             ]
    end
  end

  describe "waking" do
    test "a task waiting on nothing wakes" do
      assert Policy.wake?(nil, facts(), 0)
      assert Policy.wake?(%{}, facts(), 0)
    end

    test "on: once every task waited on has finished; a missing one counts as finished" do
      waiting = %{"on" => ["a", "b"], "policy" => "all_settled"}

      refute Policy.wake?(waiting, facts(%{"a" => "done", "b" => "running"}), 0)
      assert Policy.wake?(waiting, facts(%{"a" => "done", "b" => "failed"}), 0)
      assert Policy.wake?(waiting, facts(%{"a" => "aborted"}), 0)
    end

    test "fail_fast: one failure is enough, and the unfinished rest is aborted" do
      waiting = %{"on" => ["a", "b", "c"], "policy" => "fail_fast"}
      statuses = %{"a" => "failed", "b" => "running", "c" => "done"}

      assert Policy.wake?(waiting, facts(statuses), 0)
      assert Policy.fail_fast_ids(waiting) == ["a", "b", "c"]
      assert Policy.fail_fast_aborts(waiting, statuses) == ["b"]
      assert Policy.fail_fast_aborts(waiting, %{"a" => "done", "b" => "running"}) == []
    end

    test "all_settled never aborts the rest" do
      waiting = %{"on" => ["a", "b"], "policy" => "all_settled"}

      assert Policy.fail_fast_ids(waiting) == nil
      assert Policy.fail_fast_aborts(waiting, %{"a" => "failed", "b" => "running"}) == []
    end

    test "signal: once the signal is recorded" do
      refute Policy.wake?(%{"signal" => "go"}, facts(nil, false), 0)
      assert Policy.wake?(%{"signal" => "go"}, facts(nil, true), 0)
    end

    test "until: once the time has come; with a signal, it is a timeout" do
      waiting = %{"signal" => "go", "until" => 500}

      refute Policy.wake?(waiting, facts(nil, false), 499)
      assert Policy.wake?(waiting, facts(nil, false), 500)
      assert Policy.wake?(waiting, facts(nil, true), 0)
    end

    test "only the facts a wait names are read" do
      test = self()

      statuses = fn ids ->
        send(test, {:statuses, ids})
        %{}
      end

      assert Policy.facts(%{"signal" => "go"}, statuses, &(&1 == "go")) ==
               %{statuses: nil, signal?: true}

      refute_received {:statuses, _}

      assert Policy.facts(%{"on" => ["a"]}, statuses, fn _ -> flunk("read a signal") end) ==
               %{statuses: %{}, signal?: nil}

      assert_received {:statuses, ["a"]}
    end

    test "only a waiting task that isn't marked for abort may wake" do
      assert Policy.wakeable?(task(status: "waiting"))
      refute Policy.wakeable?(task(status: "waiting", abort_requested: true))
      refute Policy.wakeable?(task(status: "pending"))
      refute Policy.wakeable?(nil)
    end
  end

  describe "starting" do
    test "a pending task starts unless a step for it runs here" do
      assert Policy.start_action(task(), %{}, Photon.Durable.Generation, MapSet.new()) == :start

      assert Policy.start_action(
               task(),
               %{"t_1" => :step},
               Photon.Durable.Generation,
               MapSet.new()
             ) ==
               :skip
    end

    test "a task of an unregistered kind waits, and is reported once" do
      unknown = task(kind: "mystery")

      assert Policy.start_action(unknown, %{}, nil, MapSet.new()) == :unknown_kind
      assert Policy.start_action(unknown, %{}, nil, MapSet.new(["mystery"])) == :skip
    end

    test "starting a phase marks the task running and counts the run" do
      assert Policy.startable?(task(status: "pending"))
      refute Policy.startable?(task(status: "pending", abort_requested: true))
      refute Policy.startable?(task(status: "running"))
      refute Policy.startable?(nil)

      assert Policy.start(task(runs: 2)) == [status: "running", runs: 3]
    end
  end

  describe "failing" do
    test "a running task fails, unless it is marked for abort" do
      assert Policy.failable?(task(status: "running"))
      refute Policy.failable?(task(status: "running", abort_requested: true))
      refute Policy.failable?(task(status: "done"))
      refute Policy.failable?(nil)
    end

    test "a kind's on_fail may ask for a retry; anything else fails the task" do
      assert Policy.after_failure(:retry) == :retry
      assert Policy.after_failure(nil) == :fail
      assert Policy.after_failure(:ok) == :fail
      assert Policy.failed_outcome("boom") == %{"status" => "failed", "reason" => "boom"}
    end

    test "says why a step failed" do
      assert Policy.no_transition(task(phase: "request")) ==
               "the step for phase request ended without a transition"

      assert Policy.crash_reason({%RuntimeError{message: "boom"}, []}) == "boom"
      assert Policy.crash_reason(:killed) == "killed"
    end
  end

  describe "the timer" do
    test "is armed for the earliest deadline among waiting tasks" do
      conditions = [%{"until" => 2_000}, nil, %{"signal" => "go"}, %{"until" => 1_500}]
      assert Policy.timer_delay(conditions, 1_000) == 505
    end

    test "fires right away for a deadline that has passed, and at least hourly" do
      assert Policy.timer_delay([%{"until" => 10}], 1_000) == 5
      assert Policy.timer_delay([%{"until" => 10_000_000}], 0) == 3_600_005
    end

    test "isn't armed when nothing waits on time" do
      assert Policy.timer_delay([], 0) == nil
      assert Policy.timer_delay([%{"signal" => "go"}, %{"until" => "soon"}], 0) == nil
    end
  end

  describe "what waiting tasks name" do
    test "each task ID and signal key once, so they're read together" do
      tasks = [
        task(waiting: %{"on" => ["a", "b"], "policy" => "all_settled"}),
        task(waiting: %{"on" => ["b"], "signal" => "s1", "until" => 5}),
        task(waiting: %{"signal" => "s1"}),
        task(waiting: %{"signal" => "s2"}),
        task(waiting: nil)
      ]

      assert Policy.wanted(tasks) == {["a", "b"], ["s1", "s2"]}
      assert Policy.wanted([]) == {[], []}
    end
  end
end
