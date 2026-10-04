defmodule PhotonNode.SessionDriver do
  @moduledoc """
  Runs a `PhotonNode.Harness.Session` the way
  `PhotonNode.Harness.Coordinator` does, against an in-memory world instead
  of files and processes. Persisted records go to an in-memory log, the
  model request and dispatched operations are tracked as in flight, and
  timers as armed. Core tests and properties use it to play out a session
  and check what it did; nothing here touches the disk or starts a process.

  `handle/2` is a message handler (the event's step, then reconcile and
  decide); `fire/2` is a timer handler (the step, then decide);
  `resume/1` is a coordinator's start (`Session.resume/1`, then decide).
  Each keeps the effects of that one handler in `:effects`.
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  alias PhotonNode.Harness.Session

  defstruct [
    :session,
    log: [],
    effects: [],
    request: nil,
    requests: 0,
    ops: %{},
    canceled: MapSet.new(),
    grace: false,
    heartbeat: false,
    idle_timer: false,
    replies: [],
    unstartable: MapSet.new()
  ]

  @doc "A driver for `session`; `unstartable` lists operation IDs whose start fails."
  def new(session, opts \\ []) do
    %__MODULE__{session: session, unstartable: MapSet.new(Keyword.get(opts, :unstartable, []))}
  end

  @doc "Replays `records` into a fresh session, as a starting coordinator does."
  def start(session, records, opts \\ []) do
    session |> Session.replay(records) |> new(opts) |> Map.put(:log, records) |> resume()
  end

  def resume(driver), do: driver |> clear() |> run(&Session.resume/1) |> run(&Session.decide/1)

  def handle(driver, step) do
    driver |> clear() |> run(step) |> run(&Session.reconcile/1) |> run(&Session.decide/1)
  end

  def fire(driver, step), do: driver |> clear() |> run(step) |> run(&Session.decide/1)

  ## Shortcuts for the coordinator's messages

  def deliver(driver, input, config \\ nil, from \\ :caller),
    do: handle(driver, &Session.deliver(&1, config, input, from))

  @doc "The model request's answer arrives (it is no longer in flight)."
  def respond(driver, result),
    do: handle(%{driver | request: nil}, &Session.model_response(&1, result))

  def update(driver, op, from \\ nil), do: handle(driver, &Session.op_update(&1, op, from))
  def op_down(driver, op_id, reason), do: handle(driver, &Session.op_down(&1, op_id, reason))
  @doc "The grace timer fires (so it is no longer armed)."
  def grace(driver), do: fire(%{driver | grace: false}, &Session.grace_expired/1)

  @doc "The heartbeat timer fires (so it is no longer armed)."
  def heartbeat(driver), do: fire(%{driver | heartbeat: false}, &Session.heartbeat_fired/1)

  @doc "The records in the in-memory log, header excluded."
  def records(driver), do: driver.log

  @doc "Replaying the log into a fresh copy of `session` (its config and env)."
  def replayed(driver, fresh_session), do: Session.replay(fresh_session, driver.log)

  defp clear(driver), do: %{driver | effects: []}

  defp run(driver, step) do
    {session, effects} = driver.session |> step.() |> Session.take_effects()
    Enum.reduce(effects, %{driver | session: session}, &execute/2)
  end

  defp execute(effect, driver) do
    driver = %{driver | effects: driver.effects ++ [effect]}
    apply_effect(effect, driver)
  end

  defp apply_effect({:persist, kind, data}, driver) do
    record = %{"seq" => length(driver.log) + 1, "kind" => kind, "data" => data}
    %{driver | log: driver.log ++ [record]}
  end

  defp apply_effect({:reply, from, reply}, driver),
    do: %{driver | replies: driver.replies ++ [{from, reply}]}

  defp apply_effect({:warn, _message}, driver), do: driver

  defp apply_effect({:request, turn_id, _request}, driver),
    do: %{driver | request: turn_id, requests: driver.requests + 1}

  defp apply_effect(:cancel_request, driver), do: %{driver | request: nil}

  defp apply_effect({:dispatch, op}, driver) do
    if MapSet.member?(driver.unstartable, op["id"]),
      do: run(driver, &Session.dispatch_failed(&1, op, "unsupported operation type")),
      else: %{driver | ops: Map.put(driver.ops, op["id"], op)}
  end

  defp apply_effect({:cancel_op, op_id}, driver),
    do: %{driver | canceled: MapSet.put(driver.canceled, op_id)}

  defp apply_effect({:arm_grace, _ms}, driver), do: %{driver | grace: true}
  defp apply_effect(:cancel_grace, driver), do: %{driver | grace: false}
  defp apply_effect({:arm_heartbeat, _ms}, driver), do: %{driver | heartbeat: true}
  defp apply_effect(:disarm_heartbeat, driver), do: %{driver | heartbeat: false}
  defp apply_effect({:arm_idle_stop, _ms}, driver), do: %{driver | idle_timer: true}
  defp apply_effect(:disarm_idle_stop, driver), do: %{driver | idle_timer: false}
end
