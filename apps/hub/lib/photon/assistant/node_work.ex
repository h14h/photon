defmodule Photon.Assistant.NodeWork do
  @moduledoc """
  What `run_on_node` and `message_node_session` share: IDs derived from the
  tool call's task (so a rerun after a hub restart finds the same session
  and input instead of starting the work twice), a background watcher for
  the report, and a short durable wait for an early answer.

  The node's answer reaches the conversation exactly once: in the tool's
  result if it came within the wait and no report has been posted, or as
  the watcher's report otherwise. The tool decides which in the same commit
  that records its result, and a call stopped or failed after it started the
  work still leaves a watcher behind.

  The decisions and texts are pure (`resume_result/3`, `watcher/3`,
  `wait_seconds/1`, and `Photon.Assistant.Report`); `await/4`,
  `ensure_watcher/2`, `resume/2`, `online_names/0` and `known_session/1`
  read or write.
  """

  alias Photon.Assistant.Report
  alias Photon.{Durable, NodeSessions}
  alias Photon.Durable.{Signal, TaskRecord, ToolAPI, Tx}
  alias Photon.NodeSessions.{Input, Session}

  @default_wait 20
  @max_wait 120

  @doc "The session and input IDs for a tool call, derived from its task ID."
  @spec ids(ToolAPI.t()) :: %{session_id: String.t(), input_id: String.t()}
  def ids(api) do
    "t_" <> suffix = ToolAPI.task_id(api)
    %{session_id: "ns_" <> suffix, input_id: "in_" <> suffix}
  end

  @doc "Starts the watcher and parks the tool call until the answer or the deadline."
  @spec await(ToolAPI.t(), Session.t(), String.t(), integer() | nil) :: {:wait, map(), map()}
  def await(api, session, input_id, wait_seconds) do
    watcher = Durable.create_task(watcher(api, session, input_id))
    until = System.system_time(:millisecond) + wait_seconds(wait_seconds) * 1000

    {:wait, %{"signal" => Report.signal_key(input_id), "until" => until},
     parked(session, input_id, watcher.id)}
  end

  @doc "How long a call waits for a quick answer: the request, within 0 to 120 seconds."
  @spec wait_seconds(integer() | nil) :: non_neg_integer()
  def wait_seconds(requested), do: (requested || @default_wait) |> max(0) |> min(@max_wait)

  @doc "What a parked call remembers about its work."
  @spec parked(Session.t(), String.t(), String.t()) :: map()
  def parked(session, input_id, watcher_id) do
    %{
      "session_id" => session.id,
      "input_id" => input_id,
      "watcher" => watcher_id,
      "node" => session.node_id,
      "title" => session.title
    }
  end

  @doc """
  The attributes of the watcher for an input. One per input: its request
  ID makes creating it idempotent.
  """
  @spec watcher(ToolAPI.t(), Session.t(), String.t()) :: map()
  def watcher(api, session, input_id) do
    %{
      kind: "node_watch",
      conversation_id: api.conversation_id,
      background: true,
      request_id: "watch:" <> input_id,
      phase: "start",
      input: %{
        "session_id" => session.id,
        "input_id" => input_id,
        "node" => session.node_id,
        "title" => session.title,
        "tool_task_id" => ToolAPI.task_id(api)
      }
    }
  end

  @doc """
  For a call that was aborted or failed (`on_interrupt/2`): if it had
  already handed the input to a node session, make sure a watcher will
  report the answer.
  """
  @spec ensure_watcher(ToolAPI.t(), Tx.t()) :: :ok
  def ensure_watcher(api, tx) do
    %{input_id: input_id} = ids(api)

    with %Input{session_id: session_id} <- NodeSessions.input(input_id),
         %Session{} = session <- NodeSessions.get(session_id) do
      _watcher = Tx.create_task(tx, watcher(api, session, input_id))
      :ok
    else
      _no_input_yet -> :ok
    end
  end

  @doc """
  After the wait: the answer if it came and no report has been posted (the
  watcher is stopped in the same commit, so it won't post one), else a note
  that it's still going or that the report is in the conversation.
  """
  @spec resume(map(), ToolAPI.t()) :: {:commit, (Tx.t() -> {:ok, String.t(), map()})}
  def resume(state, api), do: {:commit, &resume_tx(&1, state, api.conversation_id)}

  defp resume_tx(tx, state, conversation_id) do
    signal = Tx.get_signal(tx, Report.signal_key(state["input_id"]))

    reported? =
      signal != nil and
        Tx.find_submission(tx, conversation_id, Report.request_id(state["input_id"])) != nil

    {outcome, result} = resume_result(state, signal, reported?)
    :ok = if outcome == :answer, do: stop_watcher(tx, state["watcher"]), else: :ok
    result
  end

  defp stop_watcher(tx, watcher_id) do
    case Tx.get_task(tx, watcher_id) do
      %TaskRecord{} = watcher ->
        _aborted = Tx.request_abort(tx, watcher)
        :ok

      nil ->
        :ok
    end
  end

  @doc """
  The result of a resumed call, given the input's signal (nil until the
  node answers) and whether the watcher's report was already posted.
  `:answer` means the result carries the answer, so the watcher must stop.
  """
  @spec resume_result(map(), Signal.t() | nil, boolean()) ::
          {:running | :reported | :answer, {:ok, String.t(), map()}}
  def resume_result(state, nil = _signal, _reported?),
    do: {:running, {:ok, Report.still_running(state), details(state, "running")}}

  def resume_result(state, %Signal{payload: payload}, true = _reported?) do
    {:reported, {:ok, Report.already_reported(state), details(state, Report.status(payload))}}
  end

  def resume_result(state, %Signal{payload: payload}, false = _reported?) do
    {:answer, {:ok, Report.tool_answer(state, payload), details(state, Report.status(payload))}}
  end

  defp details(state, status) do
    %{
      "session_id" => state["session_id"],
      "node" => state["node"],
      "title" => state["title"],
      "status" => status
    }
  end

  @doc "One line about a node session, for tool results."
  @spec session_line(Session.t()) :: String.t()
  def session_line(session) do
    updated = Calendar.strftime(session.updated_at, "%Y-%m-%d %H:%M UTC")

    ~s[#{session.id} on #{session.node_id}: "#{session.title}" (#{session.status}, updated #{updated})]
  end

  @doc "The `wait_seconds` parameter both node tools take."
  @spec wait_param() :: map()
  def wait_param do
    %{
      "type" => "integer",
      "description" =>
        "Seconds to wait for a quick answer before leaving the work running in the background (0 to #{@max_wait}, default #{@default_wait})."
    }
  end

  @doc "The IDs of the nodes online now."
  @spec online_names() :: [String.t()]
  def online_names, do: Photon.Nodes.list() |> Enum.map(& &1["id"])

  @doc "The node session with `id`, or an error result the model can read."
  @spec known_session(String.t()) :: {:ok, Session.t()} | {:error, String.t()}
  def known_session(id) do
    case NodeSessions.get(id) do
      nil -> {:error, "There is no node session #{id}."}
      session -> {:ok, session}
    end
  end
end
