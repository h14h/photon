defmodule Photon.Durable.ToolTask do
  @moduledoc """
  The built-in task for one tool call, owned by the generation that made it.

  `"run"` validates the arguments and calls the tool's `execute/2`; a tool may
  park itself durably (`{:wait, ...}`) and continue in `"resume"`. The result
  is committed as a `"tool_result"` entry together with the task finishing.
  A call interrupted by a hub restart reruns only if the tool says it's safe;
  otherwise the model is told it was interrupted. A call that is aborted or
  fails gives its tool's `on_interrupt/2` a chance to hand off what it
  started.

  This module is the task kind's boundary: it finds the tool, runs it, and
  commits. Whether a call runs and how its result is recorded is
  `Photon.Durable.ToolCall`.
  """

  @behaviour Photon.Durable.TaskKind

  require Logger

  alias Photon.Durable
  alias Photon.Durable.{Runtime, Tool, ToolAPI, ToolCall, Tx}

  @impl true
  def step("run", task, runtime) do
    tool = tool(task)

    case ToolCall.plan(task.input["call"], task.runs, facts(tool)) do
      {:execute, args} -> run(runtime, task, fn api -> tool.execute(args, api) end)
      {:finish, result} -> finish(runtime, task, result)
    end
  end

  def step("resume", task, runtime) do
    case tool(task) do
      nil -> finish(runtime, task, ToolCall.tool_gone())
      tool -> run(runtime, task, fn api -> tool.resume(task.checkpoint["state"], api) end)
    end
  end

  defp tool(task) do
    conversation = Durable.conversation(task.conversation_id)
    profile = Durable.profile(conversation.profile)
    ToolCall.find_tool(profile.tools(conversation), task.input["call"]["name"])
  end

  defp facts(nil), do: nil
  defp facts(tool), do: {Tool.replay(tool), tool.parameters()}

  defp run(runtime, task, fun) do
    case call_tool(task, fun) do
      {:wait, waiting, state} -> Runtime.transition(runtime, ToolCall.park(waiting, state))
      result -> finish(runtime, task, result)
    end
  end

  # A tool that raises ends its call with an error result, not a crash.
  defp call_tool(task, fun) do
    fun.(ToolAPI.new(task))
  rescue
    e ->
      Logger.error(
        "tool #{task.input["call"]["name"]} raised: " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      {:error, Exception.message(e)}
  end

  # A `{:commit, fun}` result is decided inside the commit that records it.
  defp finish(runtime, task, {:commit, fun}) when is_function(fun, 1) do
    Runtime.commit(runtime, &ToolCall.done(record(&1, task, fun.(&1))))
  end

  defp finish(runtime, task, result) do
    Runtime.commit(runtime, &ToolCall.done(record(&1, task, result)))
  end

  defp record(tx, task, result) do
    {status, entry} = ToolCall.result_entry(task.input["call"], result)
    _entry = Tx.append(tx, task.conversation_id, "tool_result", entry)
    status
  end

  @impl true
  def on_abort(task, tx) do
    interrupted(task, tx)
    record(tx, task, ToolCall.stopped())
  end

  @impl true
  def on_fail(task, reason, tx) do
    interrupted(task, tx)
    record(tx, task, {:error, reason})
  end

  defp interrupted(task, tx) do
    with tool when tool != nil <- tool(task),
         true <- Durable.implements?(tool, :on_interrupt, 2) do
      tool.on_interrupt(ToolAPI.new(task), tx)
    end
  end
end
