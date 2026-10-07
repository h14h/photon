defmodule Photon.Durable.Profile do
  @moduledoc """
  What a conversation runs with, resolved at every use so settings changes
  apply to the next request:

    * `llm/1` - `%{config: PhotonCore.LLM config, model: id, reasoning: level | nil}`,
      and optionally `:stream`, a function that runs the request in place
      of `PhotonCore.LLM.stream/3` (same arguments and result)
    * `system_prompt/1` - kept stable between requests so provider prompt
      caches stay warm
    * `tools/1` - `Photon.Durable.Tool` modules
    * `workdir/1` (optional) - the directory its tool calls work in on
      each machine, relative to the machine's workspace; nil (or no
      callback) for the workspace itself. Tools see it as
      `Photon.Durable.ToolAPI`'s `workdir`. It must not change while a
      call runs, since a call rerun after a restart asks again.

  ## Hooks

  Two optional callbacks let a profile react to what the harness stores:

    * `on_settled/3` - a generation settled the submissions it placed:
      it answered (`"done"`), couldn't (`"failed"`: the model failed, the
      round limit, or its task failed) or was stopped (`"stopped"`). See
      `t:settled/0`. A settle that closes nothing (its submissions were
      all settled earlier) still calls it, with `submissions: []`.
    * `on_tool_result/4` - a tool call's `"tool_result"` entry was
      appended, whichever way the call ended (a result, a `{:commit,
      fun}`, a raise, a Stop, a failed task); it gets the stored entry.

  Both run inside the commit that writes what they react to, so they
  happen once, exactly when the fact is stored, and anything they write
  through the `Photon.Durable.Tx` lands with it or not at all. They return
  `:ok`; whatever else they return is ignored.

  **Hooks must be total.** On a Stop or a failed task they run inside the
  Scheduler's own abort and fail commits, in the
  `Photon.Durable.Scheduler` process, and `Photon.Durable.Store` re-raises
  a commit's exception in its caller. A hook that raises there crashes the
  Scheduler; on restart it runs the same abort again and crashes again,
  until the supervisor gives up: a harness outage, not a failed task. So a
  hook takes what it is given as it is (a tool call's arguments are raw
  model output that may not decode), reads rows with lookups that return
  nil, and records less when something is missing. It doesn't rescue
  around a database call either: a failed statement leaves the
  transaction unusable. The rule is to not raise.
  """

  alias Photon.Durable.{Conversation, Entry, Submission, TaskRecord, Tx}

  @typedoc """
  What a generation's settle closed:

    * `task` - the generation, as it was when the settle began
    * `outcome` - `"done"`, `"failed"` or `"stopped"`
    * `reason` - why, for `"failed"` and `"stopped"`; nil for `"done"`
    * `answer_entry_id` - the answer's `"assistant"` entry, for `"done"`
    * `submissions` - the placed submissions this settle closed, as stored
      after it
    * `ended?` - whether the generation task ends with this settle (no
      queued input follows in the same run)
  """
  @type settled :: %{
          task: TaskRecord.t(),
          outcome: String.t(),
          reason: String.t() | nil,
          answer_entry_id: String.t() | nil,
          submissions: [Submission.t()],
          ended?: boolean()
        }

  @callback llm(Conversation.t()) :: %{
              required(:config) => map(),
              required(:model) => String.t(),
              required(:reasoning) => String.t() | nil,
              optional(:cache_key) => String.t(),
              optional(:stream) => (map(), map(), (term() -> term()) ->
                                      {:ok, map()} | {:error, term()})
            }
  @callback system_prompt(Conversation.t()) :: String.t()
  @callback tools(Conversation.t()) :: [module()]
  @callback workdir(Conversation.t()) :: String.t() | nil
  @callback on_settled(Conversation.t(), settled(), Tx.t()) :: :ok
  @callback on_tool_result(Conversation.t(), TaskRecord.t(), Entry.t(), Tx.t()) :: :ok

  @optional_callbacks workdir: 1, on_settled: 3, on_tool_result: 4
end
