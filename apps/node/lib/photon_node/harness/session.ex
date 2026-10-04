defmodule PhotonNode.Harness.Session do
  @moduledoc """
  One session's state machine, a port of unreal-agent's coordinator loop, as
  a functional core: no processes, files, timers or logging.
  `PhotonNode.Harness.Coordinator` is the server that runs it.

  A `%Session{}` is a token. Every function takes one and returns one, and
  what the world should see because of a step is recorded on it as effects,
  in order. The coordinator takes them with `take_effects/1` and runs them:

    * `{:persist, kind, data}` - append a record to the session log and
      announce it to the hub
    * `{:reply, from, reply}` - answer a caller waiting on a delivery or a
      checkpoint
    * `{:warn, message}` - log a warning
    * `{:request, turn_id, request}` - start the model request for a turn
    * `:cancel_request` - cancel the model request in flight
    * `{:dispatch, op}` - start (or resume) an operation
    * `{:cancel_op, op_id}` - ask an operation to cancel
    * `{:arm_grace, ms}`, `:cancel_grace` - the grace timer
    * `{:arm_heartbeat, ms}`, `:disarm_heartbeat` - the heartbeat timer
    * `{:arm_idle_stop, ms}`, `:disarm_idle_stop` - the idle timer

  The ordering rules are upstream's. The effects list keeps them, because a
  record's `{:persist, ...}` comes before anything that acts on it:

    1. an input is persisted before it can influence a model request;
    2. a `turn` is persisted before its request starts;
    3. a `model_response` is persisted before its tool calls are translated;
    4. a `tool_call_status` with new operations is persisted before they are
       dispatched;
    5. an operation update is persisted before it can complete a call.

  When a turn starts: a new external input starts one at once, cancelling a
  request in flight (steering); so does a response whose calls failed
  validation. Otherwise a turn starts when something is pending (finished
  results, a heartbeat), no request is in flight, and no grace period runs.

  Grace: after a response with valid tool calls, the session waits up to a
  second for those calls. If they all finish, the next turn starts at once
  with their real results. If some do, the turn starts at the deadline with
  placeholders for the rest. If none do, the model sleeps until the first
  one finishes.

  Recovery: every change that replay must reproduce goes through
  `apply_item/2`, live right after the `{:persist, ...}` effect for the same
  record (`record/3`), and on start for each record in the log
  (`replay/2`). After replay, `resume/1` translates calls recorded without
  a status, records completions known from saved operation states,
  resumes unfinished operations from their checkpoints, and asks for a turn
  if anything is pending.

  Differences from upstream: a session outlives one prompt (its coordinator
  stops after `@idle_stop_ms` of idleness and starts again on the next
  input); it records `state` items (running, idle, stopped) for the hub; a
  model that can't be reached after retries ends the run with a failed
  response instead of crashing; and scheduling order is deterministic.

  Because the coordinator is restarted automatically (by its supervisor,
  and on node boot), a hard stop recorded without its `stopped` record is
  re-armed on replay. External input that arrives while a hard stop is
  finishing is held and persisted once `stopped` is, so it gets its own
  turn instead of being swallowed by the stop.

  New turn, settings and heartbeat inputs get IDs from `PhotonCore.ID.new/1`,
  like the operations the translators build. That is the one impurity, kept
  on purpose: tests match on ID prefixes.
  """

  # Functional core (see PhotonNode.Harness): no processes, no I/O.
  use Boundary,
    type: :strict,
    deps: [
      PhotonNode.Harness.Context,
      PhotonNode.Harness.Inbox,
      PhotonNode.Harness.Operation,
      PhotonNode.Harness.SkillPrompt,
      PhotonNode.Harness.Tools,
      PhotonCore,
      PhotonCore.LLM.Error,
      Jason
    ]

  alias PhotonCore.{ID, LLM, Message}
  alias PhotonNode.Harness.{Context, Inbox, Operation, SkillPrompt, Tools}

  @grace_ms 1_000
  @idle_stop_ms 600_000
  @settings_keys ~w(model reasoning system_prompt disallowed_tools)
  @terminal_statuses Operation.terminal_statuses()

  @preamble_file Path.expand("../../../priv/prompts/preamble.md", __DIR__)
  @system_file Path.expand("../../../priv/prompts/system.md", __DIR__)
  @external_resource @preamble_file
  @external_resource @system_file
  @preamble @preamble_file |> File.read!() |> String.trim()
  @default_system @system_file |> File.read!() |> String.trim()

  @typedoc "A caller waiting for an answer (`GenServer.from/0`), or nil."
  @type from :: GenServer.from() | nil

  @typedoc "Something the coordinator does for the session; see the moduledoc."
  @type effect ::
          {:persist, String.t(), map()}
          | {:reply, GenServer.from(), term()}
          | {:warn, String.t()}
          | {:request, String.t(), LLM.request()}
          | :cancel_request
          | {:dispatch, Operation.t()}
          | {:cancel_op, String.t()}
          | {:arm_grace, pos_integer()}
          | :cancel_grace
          | {:arm_heartbeat, pos_integer()}
          | :disarm_heartbeat
          | {:arm_idle_stop, pos_integer()}
          | :disarm_idle_stop

  @typedoc """
  What the session knows about its machine, read once by the coordinator:
  the workspace, the shell commands run in, where operations keep their
  files, the skills found in the workspace, the machine line of the system
  prompt (`"host (arch)"`), and the heartbeat interval (0 disables it).
  Translators see the same map.
  """
  @type env :: %{
          required(:workspace) => String.t(),
          required(:shell) => String.t(),
          required(:operations_dir) => String.t(),
          required(:skills) => [SkillPrompt.skill()],
          required(:machine) => String.t(),
          required(:heartbeat_ms) => non_neg_integer()
        }

  @typedoc "A tool call's key: `{turn_id, call_id}`."
  @type call_key :: {String.t(), String.t()}

  @typedoc "A recorded tool call and what it waits for."
  @type call :: %{
          call: map(),
          turn_id: String.t(),
          status: Tools.status() | nil,
          ops: [String.t()],
          order: non_neg_integer()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          config: map(),
          env: env(),
          enabled: [String.t()],
          inbox: Inbox.t(),
          ctx: Context.t(),
          turn: map() | nil,
          calls: %{call_key() => call()},
          order: non_neg_integer(),
          operations: %{String.t() => Operation.t()},
          available: non_neg_integer(),
          delivered: non_neg_integer(),
          turn_inputs: non_neg_integer(),
          call_model: boolean(),
          llm: String.t() | nil,
          grace: MapSet.t(call_key()) | nil,
          heartbeat: boolean(),
          stop: %{mode: String.t(), requested: boolean()} | nil,
          deferred: [{map(), from()}],
          busy: boolean(),
          last_answer: String.t() | nil,
          last_failure: String.t() | nil,
          redispatched: MapSet.t(String.t()),
          effects: [effect()]
        }

  @enforce_keys [:id, :config, :env, :enabled, :inbox, :ctx]
  defstruct [
    :id,
    :config,
    :env,
    :enabled,
    :inbox,
    :ctx,
    turn: nil,
    calls: %{},
    order: 0,
    operations: %{},
    available: 0,
    delivered: 0,
    turn_inputs: 0,
    call_model: false,
    llm: nil,
    grace: nil,
    heartbeat: false,
    stop: nil,
    deferred: [],
    busy: false,
    last_answer: nil,
    last_failure: nil,
    redispatched: MapSet.new(),
    effects: []
  ]

  ## Building and replaying

  @doc "A new session with the config from its log header."
  @spec new(String.t(), map(), env()) :: t()
  def new(id, config, env) do
    %__MODULE__{
      id: id,
      config: config,
      env: env,
      enabled: Tools.enabled(config["disallowed_tools"], env.skills),
      inbox: Inbox.new(),
      ctx: Context.new(system_prompt(config, env))
    }
  end

  @doc """
  Applies a log's records (everything after the header) the way they were
  applied live, and seeds the inbox with the logged input IDs.
  """
  @spec replay(t(), [map()]) :: t()
  def replay(session, records) do
    session = Enum.reduce(records, session, &apply_item(&2, &1))
    input_ids = for %{"kind" => "input", "data" => %{"id" => id}} <- records, do: id
    %{session | inbox: Inbox.new(input_ids), effects: []}
  end

  @doc """
  The effects recorded so far, in order, and the session without them.
  """
  @spec take_effects(t()) :: {t(), [effect()]}
  def take_effects(session), do: {%{session | effects: []}, Enum.reverse(session.effects)}

  ## Events

  @doc """
  What a coordinator does once it has replayed its log: translates calls
  recorded without a status, records the results of calls whose
  operations finished, resumes unfinished operations, and asks for a turn
  if anything is pending. `decide/1` comes next, once the dispatches have
  run.
  """
  @spec resume(t()) :: t()
  def resume(session) do
    {session, statuses} = schedule_tool_calls(session)
    session = reconcile(session)

    session
    |> dispatch(non_terminal_ops(session))
    |> want_turn_if(Enum.any?(statuses, &needs_response?/1) or pending(session) > 0)
  end

  @doc """
  An input delivered with the session's config (`nil` for none). Changed
  settings are recorded first. `from` is answered once the input is
  persisted (or known to be a repeat, or rejected).
  """
  @spec deliver(t(), map() | nil, map(), from()) :: t()
  def deliver(session, config, input, from),
    do: session |> configure(config) |> handle_input(input, from)

  @doc """
  An operation snapshot. `from` is an operation waiting to act on it (a
  shell's `process` checkpoint): it is answered `:ok` once the snapshot is
  persisted, `:cancel` during a hard stop, or `:ignored` for an operation
  the session doesn't know or has finished.
  """
  @spec op_update(t(), Operation.t(), from()) :: t()
  def op_update(session, op, from), do: handle_op_update(session, op, from)

  @doc "The answer to the model request in flight."
  @spec model_response(t(), {:ok, LLM.response()} | {:error, LLM.Error.t()}) :: t()
  def model_response(session, result), do: process_model_response(session, session.llm, result)

  @doc """
  An operation process ended (`reason` is its exit reason). One that
  finished reported its final snapshot first, so a live operation here
  means the process died without one: a crash fails it; a clean exit (it
  stopped before starting its work, because its checkpoint wasn't
  confirmed) starts it again, once. So does `:noproc`: the process was
  already gone when it was monitored, so how it ended is unknown, and
  anything it reported has been handled.
  """
  @spec op_down(t(), String.t(), term()) :: t()
  def op_down(session, op_id, reason),
    do: op_ended(session, op_id, session.operations[op_id], reason)

  @doc "An operation couldn't be started: it fails with `reason`."
  @spec dispatch_failed(t(), Operation.t(), String.t()) :: t()
  def dispatch_failed(session, op, reason),
    do: handle_op_update(session, Operation.fail(op, reason), nil)

  @doc "The grace period ran out."
  @spec grace_expired(t()) :: t()
  def grace_expired(session), do: %{session | grace: nil}

  @doc "The heartbeat fired: the model hears which calls it is waiting for."
  @spec heartbeat_fired(t()) :: t()
  def heartbeat_fired(session), do: post_heartbeat(%{session | heartbeat: false})

  @doc "Records the result of every call whose operations have all finished."
  @spec reconcile(t()) :: t()
  def reconcile(session) do
    session.calls
    |> Enum.filter(fn {_key, entry} -> finished_call?(session, entry) end)
    |> Enum.sort_by(fn {_key, entry} -> entry.order end)
    |> Enum.reduce(session, fn {_key, entry}, session -> record_final_status(session, entry) end)
  end

  @doc """
  Decides what happens next: finish a hard stop, or start a turn, then
  arm the heartbeat, record the run state, and arm the idle timer.
  """
  @spec decide(t()) :: t()
  def decide(session) do
    session
    |> next_step()
    |> arm_heartbeat()
    |> record_run_state()
    |> arm_idle_stop()
  end

  ## Queries

  @doc "Nothing in flight, pending, called or running."
  @spec idle?(t()) :: boolean()
  def idle?(session) do
    session.llm == nil and pending(session) == 0 and map_size(session.calls) == 0 and
      non_terminal_ops(session) == []
  end

  @doc "A summary of the session's state, for status reports and tests."
  @spec info(t()) :: map()
  def info(session) do
    %{
      busy: session.busy,
      pending: pending(session),
      calls: map_size(session.calls),
      operations: length(non_terminal_ops(session)),
      llm: session.llm != nil,
      last_answer: session.last_answer,
      config: session.config
    }
  end

  @doc """
  Whether a log shows a session in the middle of work: the last run-state
  record is "running", or an external input was logged after the last
  model response or stop (the node stopped before the turn that answers it
  got going).
  """
  @spec working?([map()]) :: boolean()
  def working?(records) do
    {running, pending} = Enum.reduce(records, {false, false}, &note_work/2)
    running or pending
  end

  defp note_work(%{"kind" => "state", "data" => %{"state" => "running"}}, {_running, pending}),
    do: {true, pending}

  defp note_work(%{"kind" => "state", "data" => %{"state" => "stopped"}}, _acc),
    do: {false, false}

  defp note_work(%{"kind" => "state"}, {_running, pending}), do: {false, pending}

  defp note_work(%{"kind" => "input", "data" => %{"kind" => "external"}}, {running, _pending}),
    do: {running, true}

  defp note_work(%{"kind" => "model_response"}, {running, _pending}), do: {running, false}
  defp note_work(_record, acc), do: acc

  ## Applying records (live and replay)

  defp apply_item(session, %{"kind" => "input", "data" => input}), do: apply_input(session, input)

  defp apply_item(session, %{"kind" => "turn", "data" => turn}),
    do: %{session | turn: turn, turn_inputs: session.available, ctx: Context.commit(session.ctx)}

  defp apply_item(session, %{
         "kind" => "model_response",
         "data" => %{"turn_id" => turn_id, "response" => response}
       }) do
    session
    |> mark_turn_delivered(turn_id)
    |> add_message(turn_id, response["message"], response)
  end

  defp apply_item(session, %{"kind" => "tool_call_status", "data" => data}) do
    session
    |> overlay(data["operations"] || [])
    |> apply_status({data["turn_id"], data["call_id"]}, data["status"])
  end

  defp apply_item(session, %{"kind" => "state", "data" => %{"state" => run_state}}),
    do: apply_run_state(%{session | busy: run_state == "running"}, run_state)

  defp apply_item(session, %{"kind" => "operation", "data" => op}), do: overlay(session, [op])
  defp apply_item(session, _record), do: session

  defp mark_turn_delivered(session, turn_id) do
    if current_turn?(session.turn, turn_id),
      do: %{session | delivered: session.turn_inputs},
      else: session
  end

  defp current_turn?(nil, _turn_id), do: false
  defp current_turn?(turn, turn_id), do: turn_id == turn["id"]

  # A failed request has no message: the failure is what the run reports.
  defp add_message(session, _turn_id, nil, response),
    do: %{session | last_failure: get_in(response, ["failure", "message"])}

  defp add_message(session, turn_id, message, _response) do
    %{session | ctx: Context.add_response(session.ctx, message), last_failure: nil}
    |> note_answer(Message.text_of(message))
    |> add_calls(turn_id, Message.tool_calls(message))
  end

  defp note_answer(session, ""), do: session
  defp note_answer(session, text), do: %{session | last_answer: text}

  defp add_calls(session, turn_id, calls),
    do: Enum.reduce(calls, session, &add_call(&2, turn_id, &1))

  defp add_call(session, turn_id, call) do
    entry = %{call: call, turn_id: turn_id, status: nil, ops: [], order: session.order}

    %{
      session
      | calls: Map.put(session.calls, {turn_id, call["id"]}, entry),
        order: session.order + 1
    }
  end

  defp apply_status(session, key, status),
    do: apply_status(session, key, status, Map.fetch(session.calls, key))

  defp apply_status(session, key, status, {:ok, entry}) do
    entry = %{entry | status: status, ops: status["waiting_for"] || []}
    add_tool_result(%{session | calls: Map.put(session.calls, key, entry)}, key)
  end

  defp apply_status(session, _key, _status, :error), do: session

  defp apply_run_state(session, "stopped"),
    do: %{session | delivered: session.available, stop: nil}

  # A stop can't be pending at "idle"; an older log may still show one.
  defp apply_run_state(session, "idle"), do: %{session | stop: nil}
  defp apply_run_state(session, _running), do: session

  # A new external input starts a new question: the answer reported at the
  # next idle must come from a response after it.
  defp apply_input(session, %{"kind" => "external", "payload" => %{"content" => content}}) do
    %{
      session
      | ctx: Context.add_user(session.ctx, content),
        available: session.available + 1,
        last_answer: nil,
        last_failure: nil
    }
  end

  # A hard stop holds until its "stopped" record, also across a restart.
  defp apply_input(session, %{"kind" => "control", "payload" => %{"mode" => "hard"}}),
    do: accept_stop(session)

  defp apply_input(session, %{
         "kind" => "control",
         "payload" => %{"mode" => "heartbeat", "reason" => reason}
       }) do
    %{session | ctx: Context.add_user(session.ctx, reason), available: session.available + 1}
  end

  defp apply_input(session, %{
         "kind" => "control",
         "payload" => %{"mode" => "settings", "parameters" => params}
       }) do
    config = Map.merge(session.config, Map.take(params, @settings_keys))

    %{
      session
      | config: config,
        enabled: Tools.enabled(config["disallowed_tools"], session.env.skills),
        ctx: Context.set_system(session.ctx, system_prompt(config, session.env))
    }
  end

  defp apply_input(session, _input), do: session

  defp overlay(session, ops),
    do: %{session | operations: Enum.reduce(ops, session.operations, &Map.put(&2, &1["id"], &1))}

  ## Tool results

  # A call's result, once its status is known: an error goes in as is; a
  # call with operations shows the placeholder until they're all terminal.
  defp add_tool_result(session, key) do
    entry = session.calls[key]
    translator = Tools.resolve(entry.call["name"], session.enabled)
    ops = Enum.map(entry.ops, &session.operations[&1])
    show_result(session, key, call_result(entry, translator, ops))
  end

  defp show_result(session, _key, :unknown), do: session
  defp show_result(session, key, :running), do: placeholder(session, session.calls[key])
  defp show_result(session, key, {:finished, parts}), do: finish_call(session, key, parts)

  # What the model can see of a call now: `{:finished, parts}`, `:running`
  # (a placeholder), or `:unknown` while an operation's snapshot is missing.
  defp call_result(entry, translator, ops),
    do: call_result(entry, translator, ops, error_only?(entry.status), Enum.any?(ops, &is_nil/1))

  defp call_result(entry, nil = _translator, _ops, true = _error_only, _missing_ops),
    do: {:finished, [Message.text(entry.status["error"])]}

  defp call_result(_entry, _translator, _ops, _error_only, true = _missing_ops), do: :unknown

  # The tool no longer resolves (skills removed, or now disallowed), but its
  # operations still finish: report them generically.
  defp call_result(entry, nil = _translator, ops, _error_only, false),
    do: finished_or_running(ops, [Message.text(unavailable_result(entry.call, ops))])

  defp call_result(entry, translator, ops, _error_only, false),
    do: finished_or_running(ops, translator.format(entry.status, ops))

  defp finished_or_running(ops, parts) do
    if Enum.all?(ops, &Operation.terminal?/1), do: {:finished, parts}, else: :running
  end

  defp placeholder(session, entry) do
    ctx = Context.add_tool_result(session.ctx, entry.call["id"], entry.call["name"], [], true)
    %{session | ctx: ctx}
  end

  defp unavailable_result(call, ops) do
    outcomes = Enum.map_join(ops, "; ", &outcome/1)

    "The #{call["name"]} tool is no longer available, so its result can't be shown. " <>
      "Its work ended: #{outcomes}."
  end

  defp outcome(%{"state" => %{"terminal_error" => error}} = op) when error not in [nil, ""],
    do: "#{op["status"]} (#{error})"

  defp outcome(op), do: op["status"]

  defp finish_call(session, key, parts) do
    entry = session.calls[key]
    ctx = Context.add_tool_result(session.ctx, entry.call["id"], entry.call["name"], parts, false)

    %{
      session
      | ctx: ctx,
        calls: Map.delete(session.calls, key),
        available: session.available + 1
    }
    |> leave_grace(key)
  end

  # A finished call leaves the grace set; the timer goes with the last one.
  defp leave_grace(%{grace: nil} = session, _key), do: session

  defp leave_grace(session, key) do
    keys = MapSet.delete(session.grace, key)

    if MapSet.size(keys) == 0,
      do: %{session | grace: nil} |> emit(:cancel_grace),
      else: %{session | grace: keys}
  end

  defp error_only?(%{"error" => error} = status),
    do: error not in [nil, ""] and (status["waiting_for"] || []) == []

  defp error_only?(_status), do: false

  ## Inputs

  # New external input that arrives while a hard stop is finishing is held
  # until "stopped" is written (resume_deferred/1).
  defp handle_input(session, input, from) do
    if held_for_stop?(session, input),
      do: %{session | deferred: [{input, from} | session.deferred]},
      else: accept_input(session, input, from)
  end

  defp held_for_stop?(%{stop: nil}, _input), do: false

  defp held_for_stop?(session, %{"kind" => "external"} = input),
    do: Inbox.validate(input) == :ok and not Inbox.seen?(session.inbox, input["id"])

  defp held_for_stop?(_session, _input), do: false

  defp accept_input(session, input, from),
    do: accepted(session, input, from, Inbox.accept(session.inbox, input))

  defp accepted(session, _input, from, :duplicate), do: reply(session, from, :ok)

  defp accepted(session, input, from, {:error, reason}) do
    session
    |> warn("rejected input #{inspect(input["id"])}: #{reason}")
    |> reply(from, {:error, reason})
  end

  defp accepted(session, input, from, {:ok, inbox}) do
    %{session | inbox: inbox}
    |> record("input", input)
    |> reply(from, :ok)
    |> after_accept(input)
  end

  defp after_accept(session, %{"kind" => "control", "payload" => %{"mode" => "settings"}}),
    do: session

  defp after_accept(session, %{"kind" => "external"}),
    do: session |> clear_grace() |> want_turn_if(true)

  defp after_accept(session, _input), do: clear_grace(session)

  defp resume_deferred(%{deferred: []} = session), do: session

  defp resume_deferred(session) do
    session.deferred
    |> Enum.reverse()
    |> Enum.reduce(%{session | deferred: []}, fn {input, from}, session ->
      handle_input(session, input, from)
    end)
  end

  # Settings sent with an input are recorded only when they differ.
  defp configure(session, nil), do: session

  defp configure(session, config),
    do: reconfigure(session, settings(config), settings(session.config))

  defp reconfigure(session, same, same), do: session

  defp reconfigure(session, wanted, _current) do
    input = %{
      "id" => ID.new("settings_"),
      "kind" => "control",
      "payload" => %{
        "mode" => "settings",
        "parameters" => Map.new(@settings_keys, &{&1, wanted[&1]})
      }
    }

    handle_input(session, input, nil)
  end

  defp settings(config) do
    config
    |> Map.take(@settings_keys)
    |> Map.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  defp accept_stop(%{stop: %{mode: "hard"}} = session), do: session
  defp accept_stop(session), do: %{session | stop: %{mode: "hard", requested: false}}

  defp post_heartbeat(session) do
    running =
      session.calls
      |> Map.values()
      |> Enum.sort_by(& &1.call["id"])
      |> Enum.map(&running_call/1)

    reason =
      "Heartbeat: waited #{seconds(session.env.heartbeat_ms)} seconds for tool calls.\n" <>
        "Running: #{Jason.encode!(running)}"

    input = %{
      "id" => ID.new("hb_"),
      "kind" => "control",
      "payload" => %{"mode" => "heartbeat", "reason" => reason}
    }

    handle_input(session, input, nil)
  end

  defp running_call(entry) do
    %{
      "CallID" => entry.call["id"],
      "Name" => entry.call["name"],
      "Arguments" => entry.call["arguments"]
    }
  end

  defp seconds(milliseconds) do
    seconds = milliseconds / 1000
    if seconds == trunc(seconds), do: trunc(seconds), else: seconds
  end

  ## Turns

  defp request_model_response(session) do
    session = cancel_llm(session)
    turn = %{"id" => ID.new("turn_"), "previous" => turn_id(session.turn), "type" => "regular"}
    session = record(session, "turn", turn)

    request = %{
      model: session.config["model"],
      system: session.ctx.system,
      messages: Context.build(session.ctx),
      tools: Tools.definitions(session.enabled),
      reasoning: session.config["reasoning"],
      # The session's history grows turn by turn; its ID keys the cache.
      cache_key: session.id
    }

    %{session | llm: turn["id"], call_model: false}
    |> emit({:request, turn["id"], request})
  end

  defp turn_id(nil), do: ""
  defp turn_id(turn), do: turn["id"]

  defp cancel_llm(%{llm: nil} = session), do: session
  defp cancel_llm(session), do: %{session | llm: nil} |> emit(:cancel_request)

  defp process_model_response(session, turn_id, result) do
    data = %{"turn_id" => turn_id, "response" => response(result)}

    {session, statuses} =
      %{session | llm: nil}
      |> note_failure(turn_id, result)
      |> record("model_response", data)
      |> schedule_tool_calls()

    session
    |> dispatch(Enum.flat_map(statuses, fn {_key, _status, ops} -> ops end))
    |> after_response(statuses, Enum.any?(statuses, &needs_response?/1))
  end

  defp response({:ok, response}), do: Map.put(response, "failure", nil)

  defp response({:error, error}) do
    %{
      "message" => nil,
      "stop" => "failed",
      "usage" => nil,
      "model" => nil,
      "failure" => LLM.Error.to_map(error)
    }
  end

  defp note_failure(session, turn_id, {:error, error}),
    do: warn(session, "model request for #{turn_id} failed: #{Exception.message(error)}")

  defp note_failure(session, _turn_id, {:ok, _response}), do: session

  defp after_response(session, _statuses, true = _needs_response), do: want_turn_if(session, true)
  defp after_response(session, [], false), do: session

  defp after_response(session, statuses, false),
    do: arm_grace(session, MapSet.new(statuses, fn {key, _status, _ops} -> key end))

  defp needs_response?({_key, status, _ops}),
    do: status["error"] not in [nil, ""] or (status["waiting_for"] || []) == []

  defp want_turn_if(session, true), do: %{session | call_model: true}
  defp want_turn_if(session, false), do: session

  ## Tool calls

  # Translates calls recorded without a status, in the order the model made
  # them. Returns the session and `[{key, status, operations}]`.
  defp schedule_tool_calls(session) do
    {session, statuses} =
      session.calls
      |> Enum.filter(fn {_key, entry} -> entry.status == nil end)
      |> Enum.sort_by(fn {_key, entry} -> entry.order end)
      |> Enum.reduce({session, []}, &schedule_tool_call/2)

    {session, Enum.reverse(statuses)}
  end

  defp schedule_tool_call({key, entry}, {session, statuses}) do
    {status, ops} = translate(entry.call, session)

    data = %{
      "turn_id" => entry.turn_id,
      "call_id" => entry.call["id"],
      "status" => status,
      "operations" => ops
    }

    {record(session, "tool_call_status", data), [{key, status, ops} | statuses]}
  end

  defp translate(call, session),
    do: translate(call, session.env, Tools.resolve(call["name"], session.enabled))

  defp translate(call, _env, nil = _translator),
    do: {Tools.error_status(~s(tool "#{call["name"]}" is not available)), []}

  defp translate(call, env, translator), do: translator.translate(call, env)

  defp finished_call?(session, entry),
    do:
      entry.status != nil and entry.ops != [] and Enum.all?(entry.ops, &finished_op?(session, &1))

  defp finished_op?(session, op_id) do
    case session.operations[op_id] do
      nil -> false
      op -> Operation.terminal?(op)
    end
  end

  defp record_final_status(session, entry) do
    data = %{
      "turn_id" => entry.turn_id,
      "call_id" => entry.call["id"],
      "status" => entry.status,
      "operations" => Enum.map(entry.ops, &session.operations[&1])
    }

    record(session, "tool_call_status", data)
  end

  defp dispatch(session, ops), do: Enum.reduce(ops, session, &dispatch_op(&2, &1))

  defp dispatch_op(session, op) do
    if Operation.terminal?(op), do: session, else: emit(session, {:dispatch, op})
  end

  defp op_ended(session, _op_id, nil = _op, _reason), do: session

  defp op_ended(session, op_id, op, reason) do
    cond do
      Operation.terminal?(op) -> session
      restartable?(session, op_id, reason) -> redispatch(session, op_id, op)
      true -> fail_ended(session, op, reason)
    end
  end

  defp redispatch(session, op_id, op),
    do: %{session | redispatched: MapSet.put(session.redispatched, op_id)} |> dispatch([op])

  defp fail_ended(session, op, reason) do
    message = "the operation process exited: #{Exception.format_exit(reason)}"
    handle_op_update(session, Operation.fail(op, message), nil)
  end

  defp restartable?(session, op_id, reason),
    do:
      reason in [:normal, :shutdown, :noproc] and not MapSet.member?(session.redispatched, op_id)

  defp handle_op_update(session, op, from) do
    outcome = op_update_outcome(session.operations[op["id"]], from, session.stop)
    take_op_update(session, op, from, outcome)
  end

  defp op_update_outcome(nil = _known, _from, _stop), do: :ignored

  defp op_update_outcome(%{"status" => status}, _from, _stop) when status in @terminal_statuses,
    do: :ignored

  # A hard stop is under way: don't start anything new.
  defp op_update_outcome(_known, from, stop) when from != nil and stop != nil, do: :cancel
  defp op_update_outcome(_known, _from, _stop), do: :record

  defp take_op_update(session, op, from, :record),
    do: session |> record("operation", op) |> reply(from, :ok)

  defp take_op_update(session, _op, from, outcome), do: reply(session, from, outcome)

  defp non_terminal_ops(session),
    do: session.operations |> Map.values() |> Enum.reject(&Operation.terminal?/1)

  ## Deciding what happens next

  defp next_step(%{stop: nil} = session), do: maybe_turn(session)
  defp next_step(session), do: session |> handle_stop() |> after_stop()

  defp after_stop(%{stop: nil} = stopped), do: stopped |> resume_deferred() |> maybe_turn()
  defp after_stop(stopping), do: stopping

  defp maybe_turn(session) do
    if turn_due?(session),
      do: session |> request_model_response() |> clear_grace(),
      else: session
  end

  defp turn_due?(%{call_model: true}), do: true

  defp turn_due?(session),
    do: pending(session) > 0 and session.llm == nil and session.grace == nil

  defp handle_stop(session), do: session |> request_stop() |> finish_stop()

  defp request_stop(%{stop: %{requested: true}} = session), do: session

  defp request_stop(session) do
    session = cancel_llm(session)
    session = cancel_ops(session, non_terminal_ops(session))
    %{session | stop: %{session.stop | requested: true}, call_model: false}
  end

  defp cancel_ops(session, ops), do: Enum.reduce(ops, session, &emit(&2, {:cancel_op, &1["id"]}))

  defp finish_stop(session) do
    if non_terminal_ops(session) == [],
      do: %{record(session, "state", %{"state" => "stopped"}) | call_model: false},
      else: session
  end

  defp pending(session), do: session.available - session.delivered

  defp record_run_state(session), do: record_run_state(session, not idle?(session))

  defp record_run_state(%{busy: busy} = session, busy), do: session

  defp record_run_state(session, true = _busy),
    do: record(session, "state", %{"state" => "running"})

  defp record_run_state(session, false = _busy) do
    record(session, "state", %{
      "state" => "idle",
      "answer" => session.last_answer,
      "failure" => session.last_failure
    })
  end

  ## Timers

  defp arm_grace(session, keys), do: %{session | grace: keys} |> emit({:arm_grace, @grace_ms})

  defp clear_grace(%{grace: nil} = session), do: session
  defp clear_grace(session), do: %{session | grace: nil} |> emit(:cancel_grace)

  # Armed while the session waits only for tool calls; disarmed as soon as
  # anything else happens.
  defp arm_heartbeat(session), do: arm_heartbeat(session, waiting_only_on_calls?(session))

  defp arm_heartbeat(%{heartbeat: false} = session, true = _waiting),
    do: %{session | heartbeat: true} |> emit({:arm_heartbeat, session.env.heartbeat_ms})

  defp arm_heartbeat(%{heartbeat: true} = session, false = _waiting),
    do: %{session | heartbeat: false} |> emit(:disarm_heartbeat)

  defp arm_heartbeat(session, _waiting), do: session

  defp waiting_only_on_calls?(session) do
    session.env.heartbeat_ms > 0 and session.llm == nil and session.stop == nil and
      pending(session) == 0 and map_size(session.calls) > 0
  end

  defp arm_idle_stop(session) do
    if idle?(session),
      do: emit(session, {:arm_idle_stop, @idle_stop_ms}),
      else: emit(session, :disarm_idle_stop)
  end

  ## Effects

  # A record the session acts on: persisted (and announced) first, then
  # applied exactly as replay applies it.
  defp record(session, kind, data) do
    session
    |> emit({:persist, kind, data})
    |> apply_item(%{"kind" => kind, "data" => data})
  end

  defp reply(session, nil, _reply), do: session
  defp reply(session, from, reply), do: emit(session, {:reply, from, reply})

  defp warn(session, message), do: emit(session, {:warn, message})

  defp emit(session, effect), do: %{session | effects: [effect | session.effects]}

  ## System prompt

  defp system_prompt(config, env) do
    machine = "Machine: #{env.machine}. Workspace: #{env.workspace}."

    [
      @preamble,
      SkillPrompt.prompt(env.skills),
      config["system_prompt"] || @default_system,
      machine
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end
end
