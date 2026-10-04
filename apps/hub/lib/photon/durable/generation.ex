defmodule Photon.Durable.Generation do
  @moduledoc """
  The built-in task that answers a conversation's input: one model request per
  `"request"` phase, then the round's tool calls as child tasks, then the next
  request, until the model answers without calling tools.

  The checkpoint lists the submissions this run has placed. When the run
  answers they are settled `done`; then the oldest queued input (all queued
  steers at once) is placed and the run continues with it, so a busy
  conversation works through its inbox. A run that can't answer (the model
  failed, or too many tool rounds) settles its submissions `unanswered` and
  moves on to the inbox the same way. Steers that arrive mid-run are placed
  after the current tool round.

  A request that crashes the hub is simply made again, since nothing was
  committed. Partial output streams to watchers as `{:live, ...}` events and
  is never stored; the finished response is.

  This module is the task kind's boundary: it reads the conversation, makes
  the model request and commits. What the answer leads to, and what gets
  written, is `Photon.Durable.Turn`.
  """

  @behaviour Photon.Durable.TaskKind

  require Logger

  alias Photon.Durable
  alias Photon.Durable.{Runtime, Submission, TaskRecord, Turn, Tx}
  alias PhotonCore.LLM

  @impl true
  def step("request", task, runtime) do
    conversation = Durable.conversation(task.conversation_id)
    profile = Durable.profile(conversation.profile)
    llm = profile.llm(conversation)
    tools = profile.tools(conversation)
    system = profile.system_prompt(conversation)
    request = Turn.request(llm, system, Durable.entries(conversation.id), tools)

    live = fn event -> Durable.live(conversation.id, Map.put(event, "task", task.id)) end
    live.(%{"type" => "start"})

    result = LLM.stream(request, llm.config, &live.(Turn.live_event(&1)))
    commit_result(runtime, task, result, Turn.round(task.checkpoint))
  end

  def step("after_tools", task, runtime) do
    Runtime.commit(runtime, fn tx ->
      placed = for s <- Tx.queued(tx, task.conversation_id, "steer"), do: Durable.place(tx, s).id
      Turn.after_tools(task.checkpoint, placed)
    end)
  end

  defp commit_result(runtime, task, {:ok, response}, round) do
    Runtime.commit(runtime, &answered(&1, task, response, round))
  end

  defp commit_result(runtime, task, {:error, error}, _round) do
    message = Exception.message(error)
    Logger.warning("generation #{task.id} failed: #{message}")

    Runtime.commit(runtime, fn tx ->
      _error = Tx.append(tx, task.conversation_id, "error", Turn.request_failed(message))
      :ok = settle(tx, task, "unanswered", message)
      continue_with_inbox(tx, task, {:fail, message})
    end)
  end

  defp answered(tx, task, response, round) do
    entry = Tx.append(tx, task.conversation_id, "assistant", Turn.assistant_entry(response))
    _usage = Tx.update_doc(tx, task.conversation_id, "usage", %{}, &Turn.add_usage(&1, response))
    checkpoint = Map.put(task.checkpoint, "rounds", round)
    follow(tx, task, entry, checkpoint, Turn.outcome(response, round))
  end

  defp follow(tx, task, _entry, checkpoint, {:tool_round, calls}) do
    ids = for call <- calls, do: Tx.create_task(tx, Turn.tool_task(task, call)).id
    Turn.wait_for_tools(ids, checkpoint)
  end

  # Every call in the stored assistant entry gets a result.
  defp follow(tx, task, _entry, _checkpoint, {:round_limit, calls}) do
    Enum.each(calls, &Tx.append(tx, task.conversation_id, "tool_result", Turn.not_run(&1)))
    {error, reason, last} = Turn.round_limit()
    _error = Tx.append(tx, task.conversation_id, "error", error)
    :ok = settle(tx, task, "unanswered", reason)
    continue_with_inbox(tx, task, last)
  end

  defp follow(tx, task, entry, _checkpoint, :answer) do
    :ok = settle(tx, task, "done", entry.id)
    continue_with_inbox(tx, task, {:done, %{}})
  end

  # After the run's submissions are settled, takes the next input from the
  # inbox, or ends with `last` when there is none.
  defp continue_with_inbox(tx, task, last) do
    case Durable.next_input(Tx.queued(tx, task.conversation_id)) do
      [] -> last
      next -> Turn.next_run(for s <- next, do: Durable.place(tx, s).id)
    end
  end

  defp settle(tx, %TaskRecord{} = task, status, detail) do
    task.checkpoint
    |> Map.get("submissions", [])
    |> Enum.map(&Tx.get_submission(tx, &1))
    |> Enum.filter(&match?(%Submission{status: "placed"}, &1))
    |> Enum.each(&Tx.update_submission(tx, &1, Turn.settlement(status, detail)))
  end

  @impl true
  def on_abort(task, tx) do
    _error = Tx.append(tx, task.conversation_id, "error", Turn.stopped())
    settle(tx, task, "unanswered", "stopped")
  end

  @impl true
  def on_fail(task, reason, tx) do
    _error = Tx.append(tx, task.conversation_id, "error", Turn.failed(reason))
    settle(tx, task, "unanswered", reason)
  end
end
