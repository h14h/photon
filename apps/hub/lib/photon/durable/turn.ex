defmodule Photon.Durable.Turn do
  @moduledoc """
  The pure half of a generation (`Photon.Durable.Generation`): the model
  request a turn sends, what its answer leads to, and the entries, task
  attributes, settlements and transitions that record it. The generation
  makes the model request and commits what these functions describe.

  An answer leads to one of three outcomes (`outcome/2`):

    * `:answer` - no tool calls: the run's submissions are answered
    * `{:tool_round, calls}` - a tool task per call, and the generation
      waits for all of them to settle
    * `{:round_limit, calls}` - calls past `max_rounds/0` aren't run; each
      gets a "Not run" result so the transcript stays well formed, and the
      run's submissions go unanswered
  """

  # Functional core: no processes, no I/O.
  use Boundary,
    type: :strict,
    deps: [
      Photon.Durable.Context,
      Photon.Durable.TaskRecord,
      Photon.Durable.Tool,
      PhotonCore,
      PhotonCore.LLM.Error
    ]

  alias Photon.Durable.{Context, TaskRecord, Tool, Tx}
  alias PhotonCore.{LLM, Message}

  @max_rounds 60
  @round_limit_reason "too many tool rounds"

  @type outcome :: :answer | {:tool_round, [Message.tool_call()]} | {:round_limit, list()}

  @doc "How many tool rounds a run may take before it stops without an answer."
  @spec max_rounds() :: pos_integer()
  def max_rounds, do: @max_rounds

  @doc """
  The model request for a turn: the profile's model settings (`llm`), its
  system prompt and tools, and the transcript so far.
  """
  @spec request(map(), String.t(), [Photon.Durable.Entry.t()], [module()]) :: LLM.request()
  def request(llm, system, entries, tools) do
    %{
      model: llm.model,
      system: system,
      messages: Context.messages(entries),
      tools: Enum.map(tools, &Tool.spec/1),
      reasoning: llm[:reasoning],
      cache_key: llm[:cache_key]
    }
  end

  @doc "Which tool round this request is, counting from 1."
  @spec round(map()) :: pos_integer()
  def round(checkpoint), do: Map.get(checkpoint, "rounds", 0) + 1

  @doc "The data of the assistant entry that stores a response."
  @spec assistant_entry(LLM.response()) :: map()
  def assistant_entry(response) do
    %{
      "message" => response["message"],
      "usage" => response["usage"],
      "model" => response["model"],
      "stop" => response["stop"]
    }
  end

  @doc "What a response leads to in tool round `round`; see the moduledoc."
  @spec outcome(LLM.response(), pos_integer()) :: outcome()
  def outcome(response, round) do
    case response["message"]["tool_calls"] do
      calls when calls != [] and round < @max_rounds -> {:tool_round, calls}
      calls when calls != [] -> {:round_limit, calls}
      _ -> :answer
    end
  end

  @doc "The attributes of the tool task that runs `call` for `generation`."
  @spec tool_task(TaskRecord.t(), Message.tool_call()) :: map()
  def tool_task(%TaskRecord{} = generation, call) do
    %{
      kind: "tool",
      conversation_id: generation.conversation_id,
      owner_task_id: generation.id,
      phase: "run",
      input: %{"call" => call}
    }
  end

  @doc "The transition that waits for a round's tool tasks, then goes on with `checkpoint`."
  @spec wait_for_tools([String.t()], map()) :: Tx.transition()
  def wait_for_tools(task_ids, checkpoint),
    do: {:wait, %{"on" => task_ids, "policy" => "all_settled"}, "after_tools", checkpoint}

  @doc "The tool result entry for a call that wasn't run because of the round limit."
  @spec not_run(Message.tool_call()) :: map()
  def not_run(call) do
    %{
      "message" =>
        Message.tool_result(
          call["id"],
          "Not run: the assistant stopped after #{@max_rounds} tool rounds."
        ),
      "name" => call["name"],
      "status" => "error",
      "details" => %{}
    }
  end

  @doc "The error entry, settlement reason and final transition of a run that hit the round limit."
  @spec round_limit() :: {map(), String.t(), Tx.transition()}
  def round_limit do
    {%{"message" => "Stopped after #{@max_rounds} tool rounds without an answer."},
     @round_limit_reason, {:fail, @round_limit_reason}}
  end

  @doc "The error entry for a model request that failed with `message`."
  @spec request_failed(String.t()) :: map()
  def request_failed(message), do: %{"message" => message}

  @doc "The error entry a stopped run leaves."
  @spec stopped() :: map()
  def stopped, do: %{"message" => "Stopped.", "stopped" => true}

  @doc "The error entry a run that failed for `reason` leaves."
  @spec failed(String.t()) :: map()
  def failed(reason), do: %{"message" => "The assistant failed: #{reason}"}

  @doc """
  The changes that settle a placed submission: `"done"` with the answer
  entry's ID, or anything else as `"unanswered"` with a reason.
  """
  @spec settlement(String.t(), String.t()) :: keyword()
  def settlement("done", answer_entry_id), do: [status: "done", answer_entry_id: answer_entry_id]
  def settlement(_status, reason), do: [status: "unanswered", reason: reason]

  @doc "The transition that answers the inbox's next input (`placed`) in a fresh round count."
  @spec next_run([String.t()]) :: Tx.transition()
  def next_run(placed), do: {:next, "request", %{"submissions" => placed, "rounds" => 0}}

  @doc "The transition after a tool round: request again, with the steers `placed` meanwhile."
  @spec after_tools(map(), [String.t()]) :: Tx.transition()
  def after_tools(checkpoint, placed),
    do: {:next, "request", Map.update(checkpoint, "submissions", placed, &(&1 ++ placed))}

  @doc "Adds a response's token usage to the per-model totals in the usage doc."
  @spec add_usage(map(), LLM.response()) :: map()
  def add_usage(doc, %{"model" => model, "usage" => usage}) do
    key = model || "unknown"

    Map.update(doc, key, Map.put(usage, "requests", 1), fn totals ->
      totals
      |> Map.merge(usage, fn _k, a, b -> (a || 0) + (b || 0) end)
      |> Map.update("requests", 1, &(&1 + 1))
    end)
  end

  @doc "A model stream event as the `{:live, ...}` event watchers see."
  @spec live_event(LLM.event()) :: map()
  def live_event({:text, delta}), do: %{"type" => "text", "delta" => delta}
  def live_event({:reasoning, delta}), do: %{"type" => "reasoning", "delta" => delta}

  def live_event({:tool_call, index, name, args}),
    do: %{"type" => "tool_call", "index" => index, "name" => name, "delta" => args}

  def live_event({:retry, attempt, delay, error}) do
    %{
      "type" => "retry",
      "attempt" => attempt,
      "delay_ms" => delay,
      "message" => Exception.message(error)
    }
  end
end
