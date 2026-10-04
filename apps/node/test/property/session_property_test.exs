defmodule PhotonNode.Property.SessionTest do
  @moduledoc """
  Random sessions played through the session core
  (`PhotonNode.SessionDriver`, no processes or files): inputs, resends,
  stops, model answers with valid and invalid calls, operations that
  start, finish, fail, are canceled, crash or exit cleanly, grace and
  heartbeat timers, settings changes, and coordinator restarts between
  handlers.

  After every handler, the invariants `specs/tla/Coordinator.tla` checks
  for the coordinator hold on the core: replaying the log reproduces the
  session (`ReplayMatches`), effects keep the server's view (request, timers)
  in step with the session, a request starts only after its turn is
  persisted and at most one runs, operations start only after their status
  is persisted, a call's final status follows its operations' terminal
  snapshots (rule 5), and the context stays well formed. Once the world
  settles, every input is logged once and answered, every call has one
  final status, and the session is idle or stopped.
  """

  use PhotonNode.Case, async: true
  use ExUnitProperties

  alias PhotonNode.SessionDriver

  # PHOTON_PROPERTY_RUNS raises the run count for a deeper search.
  defp runs(default), do: String.to_integer(System.get_env("PHOTON_PROPERTY_RUNS", "#{default}"))

  ## Generators

  defp step do
    frequency([
      {5, constant(:say)},
      {2, map(integer(0..20), &{:resend, &1})},
      {1, constant(:stop)},
      {6, map(answer(), &{:answer, &1})},
      {6, map({integer(0..5), progress()}, fn {i, how} -> {:progress, i, how} end)},
      {1,
       map({integer(0..5), member_of([:killed, :normal, :noproc])}, fn {i, r} -> {:down, i, r} end)},
      {2, constant(:grace)},
      {1, constant(:heartbeat)},
      {1, map(boolean(), &{:settings, &1})},
      {1, constant(:restart)}
    ])
  end

  defp answer do
    frequency([
      {3, constant(:text)},
      {1, constant(:quiet)},
      {1, constant(:failure)},
      {4,
       map({integer(1..3), integer(0..1)}, fn {valid, invalid} -> {:calls, valid, invalid} end)}
    ])
  end

  defp progress,
    do: member_of([:checkpoint, :checkpoint, :complete, :complete, :fail, :cancel_ack])

  ## Playing a step

  defp play(:say, world), do: say(world, nil)

  defp play({:resend, _i}, %{inputs: []} = world), do: world

  defp play({:resend, i}, world),
    do:
      handle(
        world,
        &SessionDriver.deliver(&1, Enum.at(world.inputs, rem(i, length(world.inputs))))
      )

  defp play(:stop, world), do: handle(world, &SessionDriver.deliver(&1, hard_stop()))

  defp play({:answer, _how}, %{driver: %{request: nil}} = world), do: world

  defp play({:answer, how}, world),
    do: handle(world, &SessionDriver.respond(&1, model_result(how)))

  defp play({:progress, i, how}, world) do
    case pick_op(world.driver, i) do
      nil -> world
      op -> progress(world, op, how)
    end
  end

  defp play({:down, i, reason}, world) do
    case pick_op(world.driver, i) do
      nil -> world
      op -> handle(world, &SessionDriver.op_down(&1, op["id"], reason))
    end
  end

  defp play(:grace, %{driver: %{grace: true}} = world), do: handle(world, &SessionDriver.grace/1)
  defp play(:grace, world), do: world

  defp play(:heartbeat, %{driver: %{heartbeat: true}} = world),
    do: handle(world, &SessionDriver.heartbeat/1)

  defp play(:heartbeat, world), do: world

  defp play({:settings, disallow?}, world),
    do: say(world, %{"disallowed_tools" => if(disallow?, do: ["Bash"], else: [])})

  # A coordinator restart between handlers: the request in flight dies with
  # it, and the new one replays the log. Held inputs are lost with the
  # mailbox; the hub resends them (see settle/1).
  defp play(:restart, world) do
    before = %{world.driver | request: nil}
    driver = SessionDriver.start(session(), before.log)
    check_handler(%{world | driver: driver, restarts: world.restarts + 1}, before)
  end

  defp say(world, config) do
    input = external("say #{length(world.inputs)}")
    world = %{world | inputs: world.inputs ++ [input]}
    handle(world, &SessionDriver.deliver(&1, input, config))
  end

  defp model_result(:text), do: model_answer("Answer.")
  defp model_result(:quiet), do: model_answer("")
  defp model_result(:failure), do: model_failure()

  defp model_result({:calls, valid, invalid}) do
    calls =
      for(i <- 1..valid//1, do: bash_call("c#{i}", "echo #{i}")) ++
        for(i <- 1..invalid//1, do: call("x#{i}", "Nope"))

    model_answer("Working.", calls)
  end

  defp pick_op(driver, i) do
    case live_ops(driver) do
      [] -> nil
      ops -> Enum.at(ops, rem(i, length(ops)))
    end
  end

  defp live_ops(driver) do
    driver.session.operations
    |> Map.values()
    |> Enum.reject(&Operation.terminal?/1)
    |> Enum.filter(&Map.has_key?(driver.ops, &1["id"]))
    |> Enum.sort_by(& &1["id"])
  end

  defp progress(world, %{"status" => "ready"} = op, :checkpoint),
    do: handle(world, &SessionDriver.update(&1, running(op), :shell))

  defp progress(world, _op, :checkpoint), do: world

  defp progress(world, op, :complete), do: handle(world, &SessionDriver.update(&1, completed(op)))

  defp progress(world, op, :fail),
    do: handle(world, &SessionDriver.update(&1, Operation.fail(op, "boom")))

  defp progress(world, op, :cancel_ack) do
    if MapSet.member?(world.driver.canceled, op["id"]),
      do: handle(world, &SessionDriver.update(&1, canceled(op))),
      else: world
  end

  defp canceled(op),
    do: Operation.advance(op, "canceled", %{"terminal_error" => "shell operation canceled"})

  defp handle(world, fun) do
    before = world.driver
    %{world | driver: fun.(before)} |> check_handler(before)
  end

  ## Settling

  # Lets the world finish: the hub resends every input, requests are
  # answered, operations finish (or acknowledge their cancel), grace ends.
  defp settle(world) do
    world =
      Enum.reduce(world.inputs, world, fn input, world ->
        handle(world, &SessionDriver.deliver(&1, input))
      end)

    settle(world, 100)
  end

  defp settle(_world, 0), do: flunk("the session never settled")

  defp settle(world, budget) do
    driver = world.driver

    cond do
      driver.request != nil ->
        world |> handle(&SessionDriver.respond(&1, model_answer("Done."))) |> settle(budget - 1)

      (op = List.first(live_ops(driver))) != nil ->
        how = if MapSet.member?(driver.canceled, op["id"]), do: :cancel_ack, else: :complete
        world |> progress(op, how) |> settle(budget - 1)

      driver.grace ->
        world |> handle(&SessionDriver.grace/1) |> settle(budget - 1)

      true ->
        world
    end
  end

  ## What must hold after every handler

  defp project(session) do
    session
    |> Map.take(
      ~w(available delivered turn_inputs order calls operations turn config enabled last_answer last_failure busy ctx inbox)a
    )
    |> Map.put(:stop_pending, session.stop != nil)
  end

  defp check_handler(world, before) do
    driver = world.driver
    session = driver.session

    assert project(SessionDriver.replayed(driver, session())) == project(session),
           "replaying the log doesn't reproduce the session"

    assert driver.request == session.llm
    assert driver.grace == (session.grace != nil)
    assert driver.heartbeat == session.heartbeat
    assert driver.idle_timer == Session.idle?(session)
    assert session.busy == not Session.idle?(session)
    assert well_formed?(Context.build(session.ctx))

    check_effects(driver.effects, before, driver)
    check_log(driver.log)
    world
  end

  defp check_effects(effects, before, driver) do
    known_ops = ops_in_log(before.log)

    # How many requests ran when the handler started, counted back from the
    # end: a model answer clears the request before its handler runs.
    in_flight =
      if(driver.request, do: 1, else: 0) - Enum.count(effects, &match?({:request, _, _}, &1)) +
        Enum.count(effects, &(&1 == :cancel_request))

    assert in_flight in [0, 1]

    Enum.reduce(effects, {known_ops, in_flight, MapSet.new()}, fn
      {:persist, "tool_call_status", data}, {known, flight, turns} ->
        {Enum.reduce(data["operations"], known, &MapSet.put(&2, &1["id"])), flight, turns}

      {:persist, "turn", turn}, {known, flight, turns} ->
        {known, flight, MapSet.put(turns, turn["id"])}

      {:dispatch, op}, {known, flight, turns} ->
        assert MapSet.member?(known, op["id"]), "#{op["id"]} dispatched before its status"
        {known, flight, turns}

      {:request, turn_id, _request}, {known, flight, turns} ->
        assert MapSet.member?(turns, turn_id), "request for #{turn_id} before its turn"
        assert flight == 0, "a second request while one runs"
        {known, 1, turns}

      :cancel_request, {known, flight, turns} ->
        assert flight == 1, "cancelled a request that isn't running"
        {known, 0, turns}

      _effect, acc ->
        acc
    end)
  end

  defp ops_in_log(log) do
    for %{"kind" => "tool_call_status", "data" => %{"operations" => ops}} <- log,
        op <- ops,
        into: MapSet.new(),
        do: op["id"]
  end

  defp check_log(log) do
    check_turns_chain(log)
    check_finals_persisted(log)
    check_stops_hold(log)
  end

  # Turns chain, and each response answers the latest turn, at most once.
  defp check_turns_chain(log) do
    Enum.reduce(log, {"", MapSet.new()}, fn
      %{"kind" => "turn", "data" => turn}, {latest, responded} ->
        assert turn["previous"] == latest
        {turn["id"], responded}

      %{"kind" => "model_response", "data" => %{"turn_id" => turn_id}}, {latest, responded} ->
        assert turn_id == latest
        refute MapSet.member?(responded, turn_id)
        {latest, MapSet.put(responded, turn_id)}

      _record, acc ->
        acc
    end)
  end

  # Rule 5: a final status shows only terminal snapshots persisted before it.
  defp check_finals_persisted(log) do
    Enum.reduce(log, %{}, fn
      %{"kind" => "operation", "data" => op}, snapshots ->
        Map.put(snapshots, op["id"], op)

      %{"kind" => "tool_call_status", "data" => %{"operations" => [_ | _] = ops}}, snapshots ->
        if Enum.all?(ops, &Operation.terminal?/1), do: assert_persisted(ops, snapshots)
        snapshots

      _record, snapshots ->
        snapshots
    end)
  end

  defp assert_persisted(ops, snapshots) do
    for op <- ops, do: assert(snapshots[op["id"]] == op, "#{op["id"]} final before persisted")
  end

  # A hard stop holds until "stopped": no turn starts and no external input
  # is logged in between (input that arrives meanwhile waits, F4).
  defp check_stops_hold(log) do
    Enum.reduce(log, :working, fn
      %{"kind" => "input", "data" => %{"payload" => %{"mode" => "hard"}}}, _phase ->
        :stopping

      %{"kind" => "state", "data" => %{"state" => "stopped"}}, _phase ->
        :working

      %{"kind" => "turn"}, :stopping ->
        flunk("a turn started during a hard stop")

      %{"kind" => "input", "data" => %{"kind" => "external"}}, :stopping ->
        flunk("input folded into a stop")

      _record, phase ->
        phase
    end)
  end

  defp assert_one_final(statuses, call_id, turn_id) do
    finals = Enum.filter(statuses, fn d -> Enum.all?(d["operations"], &Operation.terminal?/1) end)
    assert length(finals) == 1, "#{length(finals)} final statuses for #{call_id} of #{turn_id}"
  end

  defp well_formed?([]), do: true

  defp well_formed?([%{"role" => "assistant"} = message | rest]) do
    ids = for call <- Message.tool_calls(message), do: call["id"]
    {results, rest} = Enum.split(rest, length(ids))

    Enum.map(results, &(&1["role"] == "tool" && &1["tool_call_id"])) == ids and
      not match?([%{"role" => "tool"} | _], rest) and well_formed?(rest)
  end

  defp well_formed?([%{"role" => "tool"} | _]), do: false
  defp well_formed?([_ | rest]), do: well_formed?(rest)

  ## What must hold once settled

  defp check_settled(world) do
    log = world.driver.log

    external =
      for %{"kind" => "input", "data" => %{"kind" => "external", "id" => id}} <- log, do: id

    assert Enum.sort(external) == Enum.sort(Enum.map(world.inputs, & &1["id"]))

    for {%{"kind" => "input", "data" => %{"kind" => "external", "id" => id}}, i} <-
          Enum.with_index(log) do
      assert Enum.any?(
               Enum.drop(log, i + 1),
               &(&1["kind"] == "turn" or
                   match?(%{"kind" => "state", "data" => %{"state" => "stopped"}}, &1))
             ),
             "input #{id} was never answered"
    end

    calls =
      for %{
            "kind" => "model_response",
            "data" => %{"turn_id" => turn_id, "response" => %{"message" => m}}
          } <- log,
          m != nil,
          call <- Message.tool_calls(m),
          do: {turn_id, call["id"]}

    for {turn_id, call_id} <- calls do
      statuses =
        for %{
              "kind" => "tool_call_status",
              "data" => %{"turn_id" => ^turn_id, "call_id" => ^call_id} = d
            } <- log,
            do: d

      assert [first | later] = statuses

      if first["status"]["waiting_for"] not in [nil, []],
        do: assert_one_final(later, call_id, turn_id)
    end

    assert %{"data" => %{"state" => final}} =
             log |> Enum.filter(&(&1["kind"] == "state")) |> List.last()

    assert final in ~w(idle stopped)
    assert Session.idle?(world.driver.session)
  end

  property "the session core keeps its invariants, and replaying its log reproduces it" do
    check all(steps <- list_of(step(), max_length: 40), max_runs: runs(300)) do
      world = %{driver: SessionDriver.new(session()), inputs: [], restarts: 0}
      world = Enum.reduce([:say | steps], world, &play/2)
      world |> settle() |> check_settled()
    end
  end
end
