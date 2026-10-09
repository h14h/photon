defmodule Photon.ConversationHelpers do
  @moduledoc """
  Waits and builders for tests that drive conversations on the durable
  harness: until a conversation is idle, a thread whose run has ended, Blip
  parked on a command that never finishes, a question passed to the owner.

  Every wait here listens for the conversation's commits
  (`Photon.Durable.subscribe/1`) before it reads the stored state, so a
  commit that lands between the read and the wait is still heard. A caller
  that has already subscribed passes `subscribe: false`: subscribing twice
  delivers every commit twice.
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  import ExUnit.Assertions

  import Photon.DataCase,
    only: [await_change: 2, await_change: 3, await_entry: 2, await_settled: 2]

  alias Photon.{Assistant, Durable, MachineOps, Questions, Threads}

  @doc """
  Waits until `check` holds, reading it now and after each of the
  conversation's commits. Options: `:subscribe` (true), `:timeout` (5 s in
  all).
  """
  def await_until(conversation_id, check, opts \\ []) do
    if Keyword.get(opts, :subscribe, true), do: :ok = Durable.subscribe(conversation_id)

    if not check.(),
      do: await_change(conversation_id, fn _changes -> check.() end, timeout(opts))

    :ok
  end

  @doc "Waits until the conversation has no run in progress; returns its ID. Options as `await_until/3`."
  def idle!(conversation_id, opts \\ []) do
    :ok = await_until(conversation_id, fn -> not Durable.busy?(conversation_id) end, opts)
    conversation_id
  end

  @doc """
  Starts a thread in `project` with the owner's `text` and waits until its
  run has ended; returns the thread as started. Options as `await_until/3`.
  """
  def idle_thread!(project, text, opts \\ []) do
    {:ok, thread} = Threads.start(project.id, text)
    _id = idle!(thread.id, opts)
    thread
  end

  @doc "Waits for a commit with a tool task parked waiting in conversation `c`."
  def await_tool_waiting(c) do
    await_change(c, &Enum.any?(&1.tasks, fn t -> t.kind == "tool" and t.status == "waiting" end))
  end

  @doc """
  Parks Blip on a command that never finishes, on `box`, a machine the test
  process plays (`Photon.MachineOps.fake_machine/1`), so what is posted to
  Blip queues behind its run; returns the parked message. Options:

    * `subscribe: true` - subscribe to Blip's commits first
    * `await_call: true` - also wait until the shell call is under way (the
      caller has subscribed to Blip's commits)
  """
  def park_blip!(opts \\ []) do
    blip = Assistant.conversation_id()
    :ok = MachineOps.fake_machine("box")
    if Keyword.get(opts, :subscribe, false), do: :ok = Durable.subscribe(blip)
    {:ok, parked} = Assistant.send("on box: $ sleep 1000")

    if Keyword.get(opts, :await_call, false),
      do: _call = await_entry(blip, &(&1.kind == "assistant"))

    assert Durable.busy?(blip)
    parked
  end

  @doc """
  Stops Blip's parked run, which leaves `parked` unanswered; the messages
  it kept then run. With `idle: true`, waits for those runs too. The caller
  has subscribed to Blip's commits.
  """
  def unpark_blip!(parked, opts \\ []) do
    blip = parked.conversation_id
    :ok = Assistant.stop()
    assert %{status: "unanswered"} = await_settled(blip, parked.id)
    if Keyword.get(opts, :idle, false), do: _blip = idle!(blip)
    :ok
  end

  @doc "As Blip's `ask_owner`: the question goes to the owner in Blip's words."
  def pass!(question, wording) do
    {:ok, passed} = Durable.commit(&Questions.pass_tx(&1, question.id, wording, :blip))
    passed
  end

  defp timeout(opts), do: Keyword.get(opts, :timeout, 5_000)
end
