defmodule PhotonNode.Harness.SessionTest do
  @moduledoc """
  The session core: the upstream ordering rules, when turns start, grace,
  hard stops, operation processes that end, heartbeats, settings and
  replay. Sessions run through `PhotonNode.SessionDriver`, which plays the
  coordinator's part in memory, so these tests need no processes or files.
  Tests named after a verification finding (F2, F4, ...) pin its fix on
  the core; `docs/verification.md` lists the boundary tests for each.
  """

  use PhotonNode.Case, async: true

  ## Named setups

  defp new_session(_context), do: %{driver: Driver.new(session())}

  defp asked_a_question(%{driver: driver}) do
    input = external("$ echo hi")
    %{driver: Driver.deliver(driver, input), input: input}
  end

  defp waiting_on_a_command(%{driver: driver}) do
    driver = Driver.respond(driver, model_answer("Running.", [bash_call("c1", "echo hi")]))
    [op] = Map.values(driver.ops)
    %{driver: driver, op: op}
  end

  defp request(driver) do
    {:request, _turn_id, request} = List.keyfind(driver.effects, :request, 0)
    request
  end

  defp operations_by_call(effects) do
    for {"tool_call_status", %{"call_id" => call_id, "operations" => [op]}} <- persisted(effects),
        into: %{},
        do: {call_id, op}
  end

  defp canceled(op),
    do: Operation.advance(op, "canceled", %{"terminal_error" => "shell operation canceled"})

  ## Inputs

  describe "an external input" do
    setup :new_session

    test "is persisted and answered before the turn that reads it starts (rules 1 and 2)", %{
      driver: driver
    } do
      input = external("hi")
      driver = Driver.deliver(driver, input)
      turn_id = driver.request

      assert names(driver.effects) == [
               {:persist, "input"},
               {:reply, :ok},
               {:persist, "turn"},
               {:request, turn_id},
               {:persist, "state"},
               :disarm_idle_stop
             ]

      assert [
               {"input", ^input},
               {"turn", %{"id" => ^turn_id, "previous" => ""}},
               {"state", %{"state" => "running"}}
             ] = persisted(driver.effects)
    end

    test "starts a request with the conversation, the system prompt and the enabled tools", %{
      driver: driver
    } do
      request = driver |> Driver.deliver(external("hi")) |> request()

      assert [%{"role" => "user", "content" => [%{"text" => "hi"}]}] = request.messages
      assert request.system =~ "Machine: testhost (x86_64-test). Workspace: /work."
      assert Enum.map(request.tools, & &1["name"]) == ["Bash", "ViewImage"]
      # The session's ID keys the model's cache of its history.
      assert request.cache_key == driver.session.id
    end

    test "with an ID seen before is answered but not persisted again", %{driver: driver} do
      input = external("hi")
      driver = driver |> Driver.deliver(input) |> Driver.deliver(input)

      assert names(driver.effects) == [{:reply, :ok}, :disarm_idle_stop]
    end

    test "that isn't valid is refused with a warning", %{driver: driver} do
      driver = Driver.deliver(driver, %{"id" => "x", "kind" => "nap"})

      assert names(driver.effects) == [
               :warn,
               {:reply, {:error, ~s(invalid input kind "nap")}},
               :arm_idle_stop
             ]
    end

    test "cancels the request in flight and starts a turn after the old one (steering)", %{
      driver: driver
    } do
      driver = Driver.deliver(driver, external("first"))
      first_turn = driver.request
      driver = Driver.deliver(driver, external("second"))
      second_turn = driver.request

      assert names(driver.effects) == [
               {:persist, "input"},
               {:reply, :ok},
               :cancel_request,
               {:persist, "turn"},
               {:request, second_turn},
               :disarm_idle_stop
             ]

      assert [{"input", _}, {"turn", %{"previous" => ^first_turn}}] = persisted(driver.effects)
      assert driver.requests == 2
    end
  end

  ## Model responses

  describe "a model response" do
    setup [:new_session, :asked_a_question]

    test "with no tool calls ends the run and reports its answer", %{driver: driver} do
      driver = Driver.respond(driver, model_answer("Done."))

      assert names(driver.effects) == [
               {:persist, "model_response"},
               {:persist, "state"},
               :arm_idle_stop
             ]

      assert {"state", %{"state" => "idle", "answer" => "Done.", "failure" => nil}} =
               List.last(persisted(driver.effects))

      assert Session.idle?(driver.session)
    end

    test "is persisted before its calls are translated, and their statuses before the operations start (rules 3 and 4)",
         %{driver: driver} do
      driver = Driver.respond(driver, model_answer("Running.", [bash_call("c1", "echo hi")]))
      %{"c1" => op} = operations_by_call(driver.effects)
      op_id = op["id"]

      assert names(driver.effects) == [
               {:persist, "model_response"},
               {:persist, "tool_call_status"},
               {:dispatch, op_id},
               :arm_grace,
               :arm_heartbeat,
               :disarm_idle_stop
             ]

      assert %{"status" => "ready", "state" => %{"input" => %{"command" => "echo hi"}}} = op
    end

    test "with a call that fails validation records an error result and starts a turn at once",
         %{driver: driver} do
      driver = Driver.respond(driver, model_answer("Hm.", [call("c1", "Nope")]))

      assert [
               {:persist, "model_response"},
               {:persist, "tool_call_status"},
               {:persist, "turn"},
               {:request, _},
               :disarm_idle_stop
             ] = names(driver.effects)

      assert Message.text_of(List.last(request(driver).messages)) =~
               ~s(tool "Nope" is not available)
    end

    test "that failed records the failure, and the run reports it", %{driver: driver} do
      driver = Driver.respond(driver, model_failure("connection refused"))

      assert names(driver.effects) == [
               :warn,
               {:persist, "model_response"},
               {:persist, "state"},
               :arm_idle_stop
             ]

      assert [{"model_response", %{"response" => response}}, {"state", idle}] =
               persisted(driver.effects)

      assert %{"message" => nil, "stop" => "failed"} = response
      assert response["failure"]["message"] == "connection refused"
      assert idle == %{"state" => "idle", "answer" => nil, "failure" => "connection refused"}
    end
  end

  ## Grace

  describe "the grace period" do
    setup [:new_session, :asked_a_question]

    test "a call that finishes within it starts the next turn at once, with its result", %{
      driver: driver
    } do
      %{driver: driver, op: op} = waiting_on_a_command(%{driver: driver})
      result = %{"out" => "hi\n", "err" => "", "exit_code" => 0}
      driver = Driver.update(driver, completed(op, result))

      assert [
               {:persist, "operation"},
               {:persist, "tool_call_status"},
               :cancel_grace,
               {:persist, "turn"},
               {:request, _},
               :disarm_heartbeat,
               :disarm_idle_stop
             ] = names(driver.effects)

      assert %{"role" => "tool", "tool_call_id" => "c1"} =
               tool = List.last(request(driver).messages)

      assert Message.text_of(tool) == "hi\n"
    end

    test "that ends with nothing finished starts no turn: the model waits for the first result",
         %{driver: driver} do
      %{driver: driver, op: op} = waiting_on_a_command(%{driver: driver})
      driver = Driver.grace(driver)
      assert names(driver.effects) == [:disarm_idle_stop]

      driver = Driver.update(driver, completed(op))

      assert [{:persist, "operation"}, {:persist, "tool_call_status"}, {:persist, "turn"} | _] =
               names(driver.effects)
    end

    test "that ends with some calls finished starts the turn with placeholders for the rest", %{
      driver: driver
    } do
      calls = [bash_call("c1", "echo one"), bash_call("c2", "sleep 5")]
      driver = Driver.respond(driver, model_answer("Running.", calls))
      ops = operations_by_call(driver.effects)

      driver = Driver.update(driver, completed(ops["c1"]))
      refute driver.request, "one of two calls finished, so grace keeps waiting"

      driver = Driver.grace(driver)
      [_user, _assistant, first, second] = request(driver).messages
      assert %{"tool_call_id" => "c1"} = first
      assert Message.text_of(first) == "(no output)"
      assert %{"tool_call_id" => "c2"} = second
      assert Message.text_of(second) == Context.placeholder()

      # The real result of a call whose placeholder was sent comes as a user message.
      done = %{"out" => "done", "err" => "", "exit_code" => 0}

      driver =
        driver
        |> Driver.respond(model_answer("Waiting."))
        |> Driver.update(completed(ops["c2"], done))

      late = List.last(request(driver).messages)
      assert %{"role" => "user"} = late
      assert Message.text_of(late) =~ "Result of the earlier Bash tool call c2"
      assert Message.text_of(late) =~ "done"
    end
  end

  ## Operation updates

  describe "an operation update" do
    setup [:new_session, :asked_a_question, :waiting_on_a_command]

    test "is persisted before the operation that asked hears it may go on (rule 5, F3)", %{
      driver: driver,
      op: op
    } do
      driver = Driver.update(driver, running(op), :shell)

      assert names(driver.effects) == [{:persist, "operation"}, {:reply, :ok}, :disarm_idle_stop]
      assert [{"operation", %{"state" => %{"pgid" => 4242}}}] = persisted(driver.effects)
    end

    test "for an operation the session doesn't know, or has finished, is ignored", %{
      driver: driver,
      op: op
    } do
      driver = Driver.update(driver, shell_op(id: "op_unknown"), :shell)
      assert names(driver.effects) == [{:reply, :ignored}, :disarm_idle_stop]

      driver = driver |> Driver.update(completed(op)) |> Driver.update(running(op), :shell)
      assert [{:reply, :ignored} | _] = names(driver.effects)
      refute {:persist, "operation"} in names(driver.effects)
    end
  end

  ## Hard stops

  describe "a hard stop" do
    setup [:new_session, :asked_a_question, :waiting_on_a_command]

    test "cancels the request and the operations, and records stopped once they have ended", %{
      driver: driver,
      op: op
    } do
      op_id = op["id"]
      driver = Driver.deliver(driver, hard_stop())

      assert names(driver.effects) == [
               {:persist, "input"},
               {:reply, :ok},
               :cancel_grace,
               {:cancel_op, op_id},
               :disarm_heartbeat,
               :disarm_idle_stop
             ]

      driver = Driver.update(driver, canceled(op))

      assert names(driver.effects) == [
               {:persist, "operation"},
               {:persist, "tool_call_status"},
               {:persist, "state"},
               :arm_idle_stop
             ]

      assert {"state", %{"state" => "stopped"}} = List.last(persisted(driver.effects))
    end

    test "answers a checkpoint with cancel: nothing new starts", %{driver: driver, op: op} do
      driver = driver |> Driver.deliver(hard_stop()) |> Driver.update(running(op), :shell)
      assert [{:reply, :cancel} | _] = names(driver.effects)
    end

    test "holds external input that arrives meanwhile, and answers it after stopped (F4)", %{
      driver: driver,
      op: op
    } do
      driver = Driver.deliver(driver, hard_stop())
      later = external("after the stop")
      driver = Driver.deliver(driver, later, nil, :second_caller)
      assert names(driver.effects) == [:disarm_idle_stop]

      driver = Driver.update(driver, canceled(op))

      assert [
               {:persist, "operation"},
               {:persist, "tool_call_status"},
               {:persist, "state"},
               {:persist, "input"},
               {:reply, :ok},
               {:persist, "turn"},
               {:request, _},
               {:persist, "state"},
               :disarm_idle_stop
             ] = names(driver.effects)

      assert [_op, _status, {"state", %{"state" => "stopped"}}, {"input", ^later} | _] =
               persisted(driver.effects)

      assert List.last(driver.replies) == {:second_caller, :ok}
    end
  end

  test "a hard stop recorded without stopped is re-armed when the log is replayed (F2)" do
    op = shell_op()

    log =
      records([
        {"input", external("$ true")},
        {"turn", turn("turn_a")},
        {"model_response",
         response_data("turn_a", Message.assistant("", [bash_call("c1", "true")]))},
        {"tool_call_status", status_data("turn_a", "c1", [op])},
        {"state", %{"state" => "running"}},
        {"input", hard_stop()}
      ])

    driver = Driver.start(session(), log)

    assert names(driver.effects) == [
             {:dispatch, "op_1"},
             {:cancel_op, "op_1"},
             :disarm_idle_stop
           ]
  end

  ## Operation processes that end

  describe "an operation process that ends" do
    setup [:new_session, :asked_a_question, :waiting_on_a_command]

    test "by crashing fails its operation, and the call gets the failure (F9)", %{
      driver: driver,
      op: op
    } do
      driver = Driver.op_down(driver, op["id"], :killed)

      assert [
               {:persist, "operation"},
               {:persist, "tool_call_status"},
               :cancel_grace,
               {:persist, "turn"},
               {:request, _},
               :disarm_heartbeat,
               :disarm_idle_stop
             ] = names(driver.effects)

      assert [{"operation", failed} | _] = persisted(driver.effects)
      assert failed["status"] == "failed"
      assert failed["state"]["terminal_error"] == "the operation process exited: killed"
    end

    test "cleanly before starting its work is dispatched again, once", %{driver: driver, op: op} do
      op_id = op["id"]
      driver = Driver.op_down(driver, op_id, :normal)
      assert names(driver.effects) == [{:dispatch, op_id}, :disarm_idle_stop]

      driver = Driver.op_down(driver, op_id, :noproc)
      assert [{"operation", %{"status" => "failed"}} | _] = persisted(driver.effects)
    end

    test "after its final snapshot changes nothing", %{driver: driver, op: op} do
      driver = driver |> Driver.update(completed(op)) |> Driver.respond(model_answer("Done."))
      driver = Driver.op_down(driver, op["id"], :normal)

      assert names(driver.effects) == [:arm_idle_stop]
    end
  end

  test "an operation that can't be started fails" do
    log =
      records([
        {"input", external("$ true")},
        {"turn", turn("turn_a")},
        {"model_response",
         response_data("turn_a", Message.assistant("", [bash_call("c1", "true")]))},
        {"tool_call_status", status_data("turn_a", "c1", [shell_op()])},
        {"state", %{"state" => "running"}}
      ])

    driver = Driver.start(session(), log, unstartable: ["op_1"])

    assert [{:dispatch, "op_1"}, {:persist, "operation"} | _] = names(driver.effects)

    assert [{"operation", %{"status" => "failed", "state" => state}}] = persisted(driver.effects)
    assert state["terminal_error"] == "unsupported operation type"
  end

  ## Heartbeats

  describe "the heartbeat" do
    setup [:new_session, :asked_a_question, :waiting_on_a_command]

    test "is armed while the session waits only on calls, and tells the model what runs", %{
      driver: driver
    } do
      assert driver.heartbeat
      driver = Driver.heartbeat(driver)

      assert [
               {:persist, "input"},
               :cancel_grace,
               {:persist, "turn"},
               {:request, _},
               :disarm_idle_stop
             ] = names(driver.effects)

      assert [{"input", %{"payload" => %{"mode" => "heartbeat", "reason" => reason}}} | _] =
               persisted(driver.effects)

      assert reason =~ "waited 600 seconds for tool calls"
      assert reason =~ ~s("CallID":"c1")
    end
  end

  test "with the heartbeat off, none is armed" do
    driver =
      [env: [heartbeat_ms: 0]]
      |> session()
      |> Driver.new()
      |> Driver.deliver(external("$ sleep 9"))
      |> Driver.respond(model_answer("Running.", [bash_call("c1", "sleep 9")]))

    refute driver.heartbeat
    refute :arm_heartbeat in names(driver.effects)
  end

  ## Settings

  describe "settings" do
    setup :new_session

    test "that changed are recorded before the input; unchanged ones aren't", %{driver: driver} do
      driver = Driver.deliver(driver, external("a"), %{"model" => "m2"})

      assert [{:persist, "input"}, {:persist, "input"}, {:reply, :ok} | _] = names(driver.effects)
      assert [{"input", settings}, {"input", _} | _] = persisted(driver.effects)

      assert settings["payload"]["parameters"] == %{
               "model" => "m2",
               "reasoning" => nil,
               "system_prompt" => nil,
               "disallowed_tools" => nil
             }

      assert request(driver).model == "m2"

      driver = Driver.deliver(driver, external("b"), %{"model" => "m2"})
      assert [{:persist, "input"}, {:reply, :ok} | _] = names(driver.effects)
    end

    test "change the system prompt and the tools offered", %{driver: driver} do
      config = %{"system_prompt" => "Be terse.", "disallowed_tools" => ["ViewImage"]}
      request = driver |> Driver.deliver(external("a"), config) |> request()

      assert request.system =~ "Be terse."
      assert Enum.map(request.tools, & &1["name"]) == ["Bash"]
    end
  end

  test "a call whose tool is no longer available still gets one result (F10)" do
    op = shell_op()

    log =
      records([
        {"input", external("help")},
        {"turn", turn("turn_a")},
        {"model_response",
         response_data("turn_a", Message.assistant("", [bash_call("c1", "true")]))},
        {"tool_call_status", status_data("turn_a", "c1", [op])},
        {"operation", completed(op)},
        {"state", %{"state" => "running"}}
      ])

    driver = Driver.start(session(config: %{"disallowed_tools" => ["Bash"]}), log)

    assert [{:persist, "tool_call_status"}, {:persist, "turn"}, {:request, _}, :disarm_idle_stop] =
             names(driver.effects)

    assert Message.text_of(List.last(request(driver).messages)) =~ "no longer available"

    driver = Driver.respond(driver, model_answer("Done."))
    refute {:persist, "tool_call_status"} in names(driver.effects)
  end

  ## Replay

  describe "replay" do
    setup [:new_session, :asked_a_question]

    test "of the log a session wrote rebuilds what it knows", %{driver: driver} do
      calls = [bash_call("c1", "echo one"), bash_call("c2", "sleep 5")]
      driver = Driver.respond(driver, model_answer("Running.", calls))
      ops = operations_by_call(driver.effects)

      driver =
        driver
        |> Driver.update(completed(ops["c1"]))
        |> Driver.grace()
        |> Driver.respond(model_answer("Waiting."))
        |> Driver.deliver(external("and now?"))

      replayed = Driver.replayed(driver, session())
      live = driver.session

      for field <-
            ~w(available delivered turn_inputs order calls operations turn config enabled last_answer last_failure busy ctx)a do
        assert Map.fetch!(replayed, field) == Map.fetch!(live, field), "#{field} differs"
      end

      assert replayed.inbox == live.inbox
    end
  end

  test "a coordinator resumes a call recorded without a status" do
    log =
      records([
        {"input", external("$ echo resumed")},
        {"turn", turn("turn_a")},
        {"model_response",
         response_data("turn_a", Message.assistant("Running.", [bash_call("c1", "echo resumed")]))},
        {"state", %{"state" => "running"}}
      ])

    driver = Driver.start(session(), log)
    %{"c1" => op} = operations_by_call(driver.effects)
    op_id = op["id"]

    assert names(driver.effects) == [
             {:persist, "tool_call_status"},
             {:dispatch, op_id},
             :arm_heartbeat,
             :disarm_idle_stop
           ]
  end

  ## Queries

  describe "working?/1 (NS-2)" do
    test "is true when the last run state is running" do
      assert Session.working?(records([{"state", %{"state" => "running"}}]))
      refute Session.working?(records([{"state", %{"state" => "idle"}}]))
    end

    test "is true for external input logged after the last response or stop" do
      input = {"input", external("hi")}
      response = {"model_response", response_data("turn_a", Message.assistant("ok"))}
      stopped = {"state", %{"state" => "stopped"}}

      assert Session.working?(records([input]))
      refute Session.working?(records([input, response]))
      assert Session.working?(records([input, response, input]))
      refute Session.working?(records([input, stopped]))
      refute Session.working?(records([{"input", hard_stop()}]))
    end
  end

  test "info/1 summarizes the session" do
    %{driver: driver} = %{driver: Driver.new(session())} |> asked_a_question()

    assert %{busy: true, pending: 1, calls: 0, operations: 0, llm: true, last_answer: nil} =
             Session.info(driver.session)
  end
end
