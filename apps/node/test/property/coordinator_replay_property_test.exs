defmodule PhotonNode.Property.CoordinatorReplayTest do
  @moduledoc """
  Random scripted sessions through the real harness and mock model, with the
  coordinator killed at random points and resumed from its log.

  After the hub's resend of every input (as on reconnect) and the session
  settling, the log must be well-formed, every command must have run at most
  once, and restarting the coordinator from the final log must reproduce the
  live coordinator's accounting and context without writing anything.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias PhotonCore.Message
  alias PhotonNode.Harness
  alias PhotonNode.Harness.{Context, Coordinator, Store}

  @moduletag timeout: 600_000

  setup do
    Process.register(self(), PhotonNode.Connection)
    :ok
  end

  # PHOTON_PROPERTY_RUNS raises the run count for a deeper search.
  defp runs(default), do: String.to_integer(System.get_env("PHOTON_PROPERTY_RUNS", "#{default}"))

  ## Generators

  defp prompt do
    frequency([
      {6, constant(:echo)},
      {1, constant("hello")},
      {1, constant("help")},
      {1, constant(:slow)}
    ])
  end

  defp step do
    frequency([
      {6, map(prompt(), &{:say, &1})},
      {2, map(integer(0..20), &{:resend, &1})},
      {1, constant(:stop)},
      {2, map(integer(0..8), &{:kill, &1})},
      {1, map(boolean(), &{:settings, &1})},
      {2, constant(:settle)}
    ])
  end

  defp script do
    gen all(first <- prompt(), steps <- list_of(step(), max_length: 7)) do
      # Keep within the session supervisor's restart budget (3 in 5 s),
      # leaving one restart for the final replay check.
      # At most one slow command (over a second each) keeps runs fast.
      {steps, _} =
        Enum.flat_map_reduce([{:say, first} | steps], {0, 0}, fn
          {:kill, _}, {2, slow} -> {[], {2, slow}}
          {:kill, _} = kill, {kills, slow} -> {[kill], {kills + 1, slow}}
          {:say, :slow}, {kills, 1} -> {[{:say, :echo}], {kills, 1}}
          {:say, :slow} = say, {kills, 0} -> {[say], {kills, 1}}
          other, acc -> {[other], acc}
        end)

      steps
    end
  end

  ## Running a script

  defp with_node(fun) do
    dir = Path.join(System.tmp_dir!(), "photon-replay-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    opts = [token: "test", data_dir: dir, node_id: "test", connect: false, heartbeat_ms: 600_000]
    start_supervised!({PhotonNode, opts})

    try do
      fun.(Path.join(dir, "workspace"))
    after
      stop_supervised(PhotonNode)
      File.rm_rf(dir)
      flush()
    end
  end

  defp flush do
    receive do
      {:event, _, _, _} -> flush()
      {:live, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp text(:echo, n), do: "$ echo t#{n} >> runs.log"
  defp text(:slow, n), do: "$ sleep 1.1; echo t#{n} >> runs.log"
  defp text(other, _n), do: other

  defp run_step({:say, prompt}, sid, s) do
    input = %{
      "id" => "in_#{s.n}",
      "kind" => "external",
      "payload" => %{"content" => text(prompt, s.n)}
    }

    :ok = Harness.deliver(sid, input, s.config)
    %{s | inputs: s.inputs ++ [input], n: s.n + 1, config: nil}
  end

  defp run_step({:resend, i}, sid, s) do
    :ok = Harness.deliver(sid, Enum.at(s.inputs, rem(i, length(s.inputs))))
    s
  end

  defp run_step(:stop, sid, s) do
    Harness.stop(sid)
    s
  end

  defp run_step({:kill, k}, sid, s) do
    await_events(sid, k)
    crash(sid)
    s
  end

  # A crash while a hard stop is cancelling the work: once the stop is on
  # record, and `k` records later.
  defp run_step({:stop_kill, k}, sid, s) do
    Harness.stop(sid)

    if await_match(
         sid,
         &match?(%{"kind" => "input", "data" => %{"payload" => %{"mode" => "hard"}}}, &1)
       ) do
      await_events(sid, k)
      crash(sid)
    end

    s
  end

  # Waits until the session's command has started.
  defp run_step(:await_running, sid, s) do
    await_match(
      sid,
      &match?(
        %{"kind" => "operation", "data" => %{"state" => %{"pgid" => pgid}}} when pgid > 0,
        &1
      )
    )

    s
  end

  defp run_step({:settings, disallow?}, _sid, s) do
    %{s | config: %{"disallowed_tools" => if(disallow?, do: ["Bash"], else: [])}}
  end

  defp run_step(:settle, sid, s) do
    settle(sid, s)
    s
  end

  # Lets the session make `k` more records of progress (or go quiet).
  defp await_match(sid, fun) do
    receive do
      {:event, ^sid, _, record} -> if fun.(record), do: true, else: await_match(sid, fun)
    after
      3_000 -> false
    end
  end

  defp await_events(_sid, 0), do: :ok

  defp await_events(sid, k) do
    receive do
      {:event, ^sid, _, _} -> await_events(sid, k - 1)
    after
      100 -> :ok
    end
  end

  defp crash(sid) do
    case Coordinator.whereis(sid) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
        # The supervisor has handled the exit (and restarted the child) once it answers.
        _ = DynamicSupervisor.which_children(PhotonNode.Harness.SessionSupervisor)
        :ok
    end
  end

  defp info(sid) do
    Coordinator.info(sid)
  catch
    :exit, _ -> nil
  end

  defp settle(sid, s, budget \\ 200) do
    if budget == 0, do: flunk("session #{sid} never settled: #{inspect(info(sid))}")

    case info(sid) do
      %{busy: false, llm: false, calls: 0, operations: 0, pending: 0} ->
        :ok

      nil ->
        # Not running (it stopped, or ran out of restarts): any input starts it again.
        :ok = Harness.deliver(sid, List.last(s.inputs))
        settle(sid, s, budget - 1)

      _busy ->
        receive do
          {:event, ^sid, _, _} -> settle(sid, s, budget - 1)
        after
          10_000 -> flunk("session #{sid} made no progress: #{inspect(info(sid))}")
        end
    end
  end

  ## What must hold

  defp project(state) do
    state
    |> Map.take(
      ~w(available delivered turn_inputs order calls operations turn config enabled last_answer last_failure busy)a
    )
    |> Map.put(:seen, state.inbox.seen)
    |> Map.put(:ctx, state.ctx)
    |> Map.put(:messages, Context.build(state.ctx))
  end

  defp well_formed?([]), do: true

  defp well_formed?([%{"role" => "assistant"} = a | rest]) do
    ids = for c <- Message.tool_calls(a), do: c["id"]
    {results, rest} = Enum.split(rest, length(ids))

    Enum.map(results, &(&1["role"] == "tool" && &1["tool_call_id"])) == ids and
      not match?([%{"role" => "tool"} | _], rest) and well_formed?(rest)
  end

  defp well_formed?([%{"role" => "tool"} | _]), do: false
  defp well_formed?([_ | rest]), do: well_formed?(rest)

  defp check_log(records, s, workspace, opts) do
    assert Enum.map(records, & &1["seq"]) == Enum.to_list(0..(length(records) - 1))

    calls = calls_made(records)
    statuses = for %{"kind" => "tool_call_status", "data" => d} <- records, do: d

    check_inputs_logged(records, s)
    check_turns_chain(records)
    check_call_statuses(calls, statuses)
    check_commands_ran(calls, statuses, workspace)

    # A hard stop ends the work: no turn starts after it until new input.
    if opts[:stops], do: check_stops(records)

    check_inputs_answered(records)

    # The session ended its work.
    assert %{"data" => %{"state" => final}} =
             records |> Enum.filter(&(&1["kind"] == "state")) |> List.last()

    assert final in ~w(idle stopped)
  end

  # Every input the hub sent is in the log exactly once.
  defp check_inputs_logged(records, s) do
    external =
      for %{"kind" => "input", "data" => %{"kind" => "external", "id" => id}} <- records, do: id

    assert Enum.sort(external) == Enum.sort(Enum.map(s.inputs, & &1["id"])),
           "external inputs #{inspect(external)}"
  end

  # Turns chain, and each gets at most one response, made while it was current.
  defp check_turns_chain(records) do
    Enum.reduce(records, {"", MapSet.new()}, fn
      %{"kind" => "turn", "data" => turn}, {latest, responded} ->
        assert turn["previous"] == latest, "turn #{turn["id"]} follows #{inspect(latest)}"
        {turn["id"], responded}

      %{"kind" => "model_response", "data" => %{"turn_id" => turn_id}}, {latest, responded} ->
        assert turn_id == latest, "response for #{turn_id} while #{latest} is current"
        refute MapSet.member?(responded, turn_id), "two responses for #{turn_id}"
        {latest, MapSet.put(responded, turn_id)}

      _, acc ->
        acc
    end)
  end

  defp calls_made(records) do
    for %{
          "kind" => "model_response",
          "data" => %{"turn_id" => t, "response" => %{"message" => m}}
        } <- records,
        m != nil,
        call <- Message.tool_calls(m),
        do: {{t, call["id"]}, call}
  end

  defp statuses_of(statuses, {turn_id, call_id}),
    do: Enum.filter(statuses, &(&1["turn_id"] == turn_id and &1["call_id"] == call_id))

  # Every call gets a status; every call with operations exactly one final one.
  defp check_call_statuses(calls, statuses) do
    for {key, _call} <- calls do
      mine = statuses_of(statuses, key)
      assert mine != [], "no status for #{inspect(key)}"
      [first | later] = mine

      if first["status"]["waiting_for"] not in [nil, []] do
        finals = Enum.filter(later, &final_status?/1)
        assert length(finals) == 1, "#{length(finals)} final statuses for #{inspect(key)}"
      end
    end
  end

  defp final_status?(status),
    do: Enum.all?(status["operations"], &(&1["status"] in ~w(completed failed canceled)))

  # Each command ran at most once, and at least once if it completed.
  defp check_commands_ran(calls, statuses, workspace) do
    runs =
      case File.read(Path.join(workspace, "runs.log")) do
        {:ok, body} -> String.split(body, "\n", trim: true)
        {:error, _} -> []
      end

    for {key, call} <- calls,
        call["name"] == "Bash",
        [_, tag] <- [Regex.run(~r/echo (t\d+) >>/, call["arguments"])] do
      ran = Enum.count(runs, &(&1 == tag))
      same = Enum.count(calls, fn {_, other} -> other["arguments"] == call["arguments"] end)
      assert ran <= same, "#{tag} ran #{ran} times for #{same} call(s)"

      if completed?(List.last(statuses_of(statuses, key))),
        do: assert(ran >= 1, "#{tag} completed without running")
    end
  end

  defp completed?(final) do
    match?(
      %{
        "operations" => [
          %{"status" => "completed", "state" => %{"result" => %{"exit_code" => 0}}}
        ]
      },
      final
    )
  end

  # Every external input is answered by a later turn, unless a stop ends the work.
  defp check_inputs_answered(records) do
    for {%{"kind" => "input", "data" => %{"kind" => "external", "id" => id}}, i} <-
          Enum.with_index(records) do
      later = Enum.drop(records, i + 1)
      assert Enum.any?(later, &answers?/1), "input #{id} was never answered"
    end
  end

  defp answers?(record),
    do:
      record["kind"] == "turn" or
        match?(%{"kind" => "state", "data" => %{"state" => "stopped"}}, record)

  defp check_stops(records) do
    Enum.reduce(records, :working, fn
      %{"kind" => "input", "data" => %{"kind" => "control", "payload" => %{"mode" => "hard"}}},
      _ ->
        :stopping

      %{"kind" => "input", "data" => %{"kind" => "external"}}, _ ->
        :working

      %{"kind" => "turn", "seq" => seq}, :stopping ->
        flunk("turn at #{seq} started after a hard stop with no new input")

      _, phase ->
        phase
    end)
  end

  defp run_script(script, check_opts) do
    with_node(fn workspace ->
      sid = "replay" <> Integer.to_string(System.unique_integer([:positive]))
      s = Enum.reduce(script, %{inputs: [], n: 0, config: nil}, &run_step(&1, sid, &2))

      # The hub resends every input it isn't sure arrived, as on reconnect.
      for input <- s.inputs, do: :ok = Harness.deliver(sid, input)
      settle(sid, s)

      records = Store.read(sid)
      check_log(records, s, workspace, check_opts)

      live = :sys.get_state(Coordinator.whereis(sid)).session
      assert well_formed?(Context.build(live.ctx))

      crash(sid)
      resumed = :sys.get_state(Coordinator.whereis(sid)).session

      assert Store.read(sid) == records, "restarting an idle session wrote to its log"
      assert project(resumed) == project(live)
    end)
  end

  property "a coordinator restarted from its log reproduces the live session" do
    check all(script <- script(), max_runs: runs(30)) do
      run_script(script, [])
    end
  end

  # Spec 6.10 doesn't re-apply stops on resume, but this coordinator is
  # restarted automatically (and resumed on node boot), so a crash between
  # recording a hard stop and finishing it must not undo the user's stop:
  # the stop is re-armed from the log.
  property "a hard stop holds when the coordinator crashes while stopping" do
    check all(
            k <- integer(0..3),
            max_runs: runs(10)
          ) do
      run_script([{:say, :slow}, :await_running, {:stop_kill, k}], stops: true)
    end
  end
end
