defmodule Photon.Property.DurableModelTest do
  @moduledoc """
  A model-based test of the durable harness with `Photon.TestProfile`:
  random interleavings of submissions (follow-ups, steers, retried request
  IDs), the `"go"` signal its wait tool parks on, aborts, and restarts of
  the scheduler and store.

  Invariants: a conversation never has two active runs; a retried request ID
  never submits twice; once `"go"` has fired and the harness is quiet, every
  submission has settled, no task is left unfinished, every tool call has
  exactly one result, and the model input is well formed.
  """

  use Photon.DataCase, async: false
  use ExUnitProperties

  import Ecto.Query

  alias Photon.Durable.{Context, Entry, Scheduler, Submission, TaskRecord}
  alias PhotonCore.Message

  @moduletag :durable
  @moduletag timeout: 600_000

  setup do
    Durable.subscribe_global()

    # The lazy-loading property below unloads Generation; load the kinds up
    # front so a property never starts with one missing.
    Code.ensure_loaded!(Photon.Durable.Generation)
    Code.ensure_loaded!(Photon.Durable.ToolTask)

    profiles = Application.get_env(:photon, Photon.Durable)[:profiles]
    put_profiles(Map.put(profiles, "slow", Photon.Property.SlowProfile))
    on_exit(fn -> put_profiles(profiles) end)
    :ok
  end

  defp put_profiles(profiles) do
    config = Application.get_env(:photon, Photon.Durable)
    Application.put_env(:photon, Photon.Durable, Keyword.put(config, :profiles, profiles))
  end

  defp runs(default), do: String.to_integer(System.get_env("PHOTON_PROPERTY_RUNS", "#{default}"))

  ## Commands

  defp command do
    frequency([
      {6,
       gen all(
             text <- member_of(["wait", "hi"]),
             mode <- member_of(["follow_up", "steer"]),
             request_id <- one_of([constant(nil), member_of(["r1", "r2"])])
           ) do
         {:submit, text, mode, request_id}
       end},
      {2, constant(:go)},
      {1, constant(:rearm)},
      {2, constant(:abort)},
      {1, constant(:restart)},
      {1, constant(:restart_scheduler)},
      {2, constant(:settle)}
    ])
  end

  ## Harness control

  defp start_harness do
    start_supervised!({Task.Supervisor, name: Photon.Durable.TaskSupervisor})
    start_supervised!(Photon.Durable.Store)
    start_supervised!(Photon.Durable.Scheduler)
  end

  defp stop_harness(task_supervisor?) do
    stop_supervised!(Photon.Durable.Scheduler)
    stop_supervised!(Photon.Durable.Store)
    if task_supervisor?, do: stop_supervised!(Photon.Durable.TaskSupervisor)
  end

  # Each run starts from an empty database with a fresh harness.
  defp fresh do
    stop_harness(true)

    for table <- ~w(conversations entries docs tasks submissions signals),
        do: Repo.query!("DELETE FROM #{table}")

    start_harness()
  end

  defp run(:restart, _c, s) do
    # The whole harness stops, as when the hub restarts: steps in flight die.
    stop_harness(true)
    start_harness()
    s
  end

  defp run(:restart_scheduler, _c, s) do
    # Only the scheduler and store restart; steps in flight keep running.
    stop_harness(false)
    start_supervised!(Photon.Durable.Store)
    start_supervised!(Photon.Durable.Scheduler)
    s
  end

  defp run({:submit, text, mode, request_id}, c, s) do
    {:ok, submission} = Durable.submit(c, text, when_busy: mode, request_id: request_id)

    case request_id && s.requests[request_id] do
      nil ->
        :ok

      earlier ->
        assert submission.id == earlier, "request #{request_id} submitted twice"
    end

    requests =
      if request_id, do: Map.put_new(s.requests, request_id, submission.id), else: s.requests

    %{s | requests: requests}
  end

  defp run(:go, _c, s) do
    Durable.signal("go")
    s
  end

  defp run(:rearm, _c, s) do
    # Test-only: forget the signal so later waits park again.
    Repo.delete_all(from(sig in Photon.Durable.Signal, where: sig.key == "go"))
    s
  end

  defp run(:abort, c, s) do
    Durable.abort(c)
    s
  end

  # Restarts the scheduler and store while a generation step is inside its
  # model request (if one gets there within a second).
  defp run(:restart_mid_request, c, s) do
    if await_request(c, 50), do: run(:restart_scheduler, c, s), else: s
  end

  defp run(:settle, _c, s) do
    settle()
    s
  end

  # Quiet: every unfinished task is waiting on something that hasn't happened.
  defp settle(budget \\ 300) do
    if budget == 0, do: flunk("the harness never settled: #{inspect(live())}")
    flush_task_changes()
    :ok = Scheduler.sync()
    now = System.system_time(:millisecond)
    tasks = live()

    if Enum.all?(
         tasks,
         &(&1.status == "waiting" and not &1.abort_requested and not Scheduler.wake?(&1, now))
       ) do
      :ok
    else
      receive do
        {:durable_tasks, _} -> settle(budget - 1)
      after
        5_000 -> flunk("no task progress: #{inspect(live())}")
      end
    end
  end

  defp await_request(_c, 0), do: false

  defp await_request(c, budget) do
    running =
      Repo.exists?(
        from(t in TaskRecord,
          where: t.conversation_id == ^c and t.kind == "generation" and t.status == "running"
        )
      )

    if running do
      true
    else
      receive do
        {:durable_tasks, _} -> await_request(c, budget - 1)
      after
        1_000 -> false
      end
    end
  end

  defp flush_task_changes do
    receive do
      {:durable_tasks, _} -> flush_task_changes()
    after
      0 -> :ok
    end
  end

  defp live do
    terminal = TaskRecord.terminal_statuses()
    Repo.all(from(t in TaskRecord, where: t.status not in ^terminal))
  end

  ## Invariants

  defp active_runs(c) do
    terminal = TaskRecord.terminal_statuses()

    Repo.aggregate(
      from(t in TaskRecord,
        where:
          t.conversation_id == ^c and is_nil(t.owner_task_id) and t.background == false and
            t.status not in ^terminal
      ),
      :count
    )
  end

  defp walk([]), do: :ok

  defp walk([%{"role" => "assistant"} = a | rest]) do
    ids = for call <- Message.tool_calls(a), do: call["id"]
    {results, rest} = Enum.split(rest, length(ids))

    if Enum.map(results, &(&1["role"] == "tool" && &1["tool_call_id"])) == ids and
         not match?([%{"role" => "tool"} | _], rest),
       do: walk(rest),
       else: {:error, ids}
  end

  defp walk([%{"role" => "tool"} = t | _]), do: {:error, t}
  defp walk([_ | rest]), do: walk(rest)

  defp check_quiet(c) do
    entries = Durable.entries(c)
    submissions = Repo.all(from(s in Submission, where: s.conversation_id == ^c))

    # Every submission settled.
    unsettled =
      for s <- submissions,
          s.status not in ~w(done unanswered withdrawn),
          do: {s.id, s.mode, s.status}

    assert unsettled == [], "unsettled submissions: #{inspect(unsettled)}"

    # Nothing left running.
    assert live() == []

    # Every tool call has exactly one result.
    calls =
      for %Entry{kind: "assistant"} = e <- entries,
          call <- Message.tool_calls(e.data["message"]),
          do: call["id"]

    results =
      for %Entry{kind: "tool_result"} = e <- entries, do: e.data["message"]["tool_call_id"]

    assert Enum.sort(results) == Enum.sort(calls),
           "calls #{inspect(calls)}, results #{inspect(results)}"

    # Settled submissions point at their entries.
    by_id = Map.new(entries, &{&1.id, &1})

    for s <- submissions, s.status in ~w(done unanswered) do
      assert %Entry{kind: "user"} = by_id[s.entry_id]
    end

    for s <- submissions, s.status == "done" do
      assert %Entry{kind: "assistant", data: %{"message" => answer}} = by_id[s.answer_entry_id]
      assert Message.tool_calls(answer) == []
    end

    # The model input is well formed.
    assert walk(Context.messages(entries)) == :ok
  end

  # The stored transcript itself (not just the model's view) keeps each
  # call's result before the next message.
  defp check_transcript(c) do
    kinds =
      for e <- Durable.entries(c), e.kind in ~w(user assistant tool_result) do
        case e.kind do
          "assistant" -> {:assistant, Enum.map(Message.tool_calls(e.data["message"]), & &1["id"])}
          "tool_result" -> {:result, e.data["message"]["tool_call_id"]}
          "user" -> :user
        end
      end

    Enum.reduce(kinds, MapSet.new(), fn
      {:assistant, ids}, open ->
        assert MapSet.size(open) == 0,
               "assistant entry while #{inspect(MapSet.to_list(open))} had no result"

        MapSet.new(ids)

      {:result, id}, open ->
        assert MapSet.member?(open, id), "result for #{id} outside its round"
        MapSet.delete(open, id)

      :user, open ->
        assert MapSet.size(open) == 0,
               "user entry while #{inspect(MapSet.to_list(open))} had no result"

        open
    end)
  end

  defp run_script(commands, opts) do
    fresh()
    c = Durable.create_conversation(opts[:profile] || "test").id

    s =
      Enum.reduce(commands, %{requests: %{}}, fn command, s ->
        s = run(command, c, s)
        assert active_runs(c) <= 1
        s
      end)

    # Let everything finish: the signal fires (for good) and the harness quiets.
    Durable.signal("go")
    settle()
    assert active_runs(c) == 0
    if opts[:settled], do: check_quiet(c)
    if opts[:transcript], do: check_transcript(c)
    _ = s
  end

  ## Properties

  property "at most one active run, and retried requests never submit twice" do
    check all(commands <- list_of(command(), max_length: 12), max_runs: runs(30)) do
      run_script(commands, [])
    end
  end

  # Covers a submission that arrives after an abort and before the scheduler
  # finishes it: it is queued behind the aborting run and must start the
  # next run once that run is aborted (it used to stay queued for good).
  property "once the harness is quiet, every submission has settled" do
    check all(commands <- list_of(command(), max_length: 12), max_runs: runs(30)) do
      run_script(commands, settled: true)
    end
  end

  property "the stored transcript keeps each call's results within its round" do
    check all(
            commands <-
              list_of(command() |> filter(&(&1 != :restart_scheduler)), max_length: 12),
            max_runs: runs(30)
          ) do
      run_script(commands, transcript: true)
    end
  end

  # A task kind's on_abort/on_fail must be found even if the module isn't
  # loaded yet (function_exported?/3 alone says no). In an interactive VM
  # (dev, test) a run aborted before any generation step ran in that VM used
  # to be aborted without on_abort: no "Stopped." entry, and its input
  # stayed "placed" forever.
  property "a run aborted before its task module is loaded still settles its input" do
    check all(text <- member_of(["hi", "wait"]), max_runs: 5) do
      fresh()
      c = Durable.create_conversation("test").id
      # Simulate a fresh VM: the generation module isn't loaded yet.
      :code.purge(Photon.Durable.Generation)
      :code.delete(Photon.Durable.Generation)

      {:ok, s} = Durable.submit(c, text)
      Durable.abort(c)
      settle()

      assert Repo.get(Submission, s.id).status == "unanswered"
      assert "error" in Enum.map(Durable.entries(c), & &1.kind)
      Code.ensure_loaded!(Photon.Durable.Generation)
    end
  end

  # The scheduler can crash and restart on its own (the application is
  # one_for_one), leaving steps it started running. The new scheduler resets
  # their tasks to pending and runs them again; the old step's commit must
  # be fenced out so a phase is committed once. A slower model widens the
  # window.
  property "the stored transcript keeps each call's results within its round across scheduler restarts" do
    check all(
            queued <- list_of(member_of(["hi", "wait"]), max_length: 2),
            max_runs: 5
          ) do
      commands =
        [{:submit, "wait", "follow_up", nil}] ++
          Enum.map(queued, &{:submit, &1, "follow_up", nil}) ++ [:restart_mid_request]

      run_script(commands, transcript: true, profile: "slow")
    end
  end
end
