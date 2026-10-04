defmodule Photon.Assistant.NodeWatch do
  @moduledoc """
  A background task that waits for node work to finish and reports it into
  the assistant's conversation as a follow-up, which wakes the assistant.

  It waits on the durable signal `"node_input:" <> input_id`, so a hub
  restart in between doesn't lose the report, and the report's request ID
  keeps a restart from posting it twice. The tool that started the work
  aborts the watcher if it already got the answer itself; while that call
  is still going, the watcher waits for it to finish first, so a quick
  answer comes back as the call's result. A step that crashes runs again;
  after three tries the watcher reports what it knows.

  It waits a day at most. Node work can take hours, but work its node lost
  (the node was wiped, say) would otherwise keep a watcher waiting forever.
  After the deadline it reports that it stopped waiting, and an answer that
  comes later is still on the node session.

  The report's text is `Photon.Assistant.Report`'s.
  """

  @behaviour Photon.Durable.TaskKind

  alias Photon.Assistant.Report
  alias Photon.Durable
  alias Photon.Durable.{Runtime, Signal, TaskRecord, Tx}

  @max_runs 3
  @deadline_ms 24 * 60 * 60 * 1000

  @impl true
  def step("start", task, runtime) do
    Runtime.transition(runtime, wait_for_signal(task))
  end

  def step("report", task, runtime) do
    call = task.input["tool_task_id"] && Durable.task(task.input["tool_task_id"])

    if call_live?(call) do
      Runtime.transition(runtime, wait_for_call(call))
    else
      # The signal or the deadline woke it; without a signal, the deadline.
      payload = Durable.signal_payload(signal_key(task)) || Report.no_answer(@deadline_ms)

      Runtime.commit(runtime, fn tx ->
        :ok = submit_report(tx, task, payload)
        {:done, %{}}
      end)
    end
  end

  @doc false
  # The first wait: for the node's answer, until the deadline, which counts
  # from the watcher's creation so a restart doesn't move it.
  @spec wait_for_signal(TaskRecord.t()) :: Durable.Tx.transition()
  def wait_for_signal(task) do
    until = DateTime.to_unix(task.inserted_at, :millisecond) + @deadline_ms
    {:wait, %{"signal" => signal_key(task), "until" => until}, "report", %{}}
  end

  @doc false
  # While the call that started the work is live, the watcher waits for it,
  # so a quick answer comes back as the call's result.
  @spec call_live?(TaskRecord.t() | nil | false) :: boolean()
  def call_live?(%TaskRecord{abort_requested: false} = call), do: not TaskRecord.terminal?(call)
  def call_live?(_call), do: false

  @doc false
  @spec wait_for_call(TaskRecord.t()) :: Durable.Tx.transition()
  def wait_for_call(%TaskRecord{id: id}), do: {:wait, %{"on" => [id]}, "report", %{}}

  defp signal_key(task), do: Report.signal_key(task.input["input_id"])

  # A crashed step runs again a few times; then the watcher gives up, and
  # posts the answer if it has come, or says it lost track.
  @impl true
  def on_fail(%{runs: runs}, _reason, _tx) when runs < @max_runs, do: :retry

  def on_fail(task, reason, tx) do
    payload =
      case Tx.get_signal(tx, signal_key(task)) do
        %Signal{payload: payload} -> payload
        nil -> Report.lost_track(reason)
      end

    submit_report(tx, task, payload)
  end

  defp submit_report(tx, task, payload) do
    input = task.input

    _report =
      Durable.submit_tx(tx, task.conversation_id, Report.node_report(input, payload),
        request_id: Report.request_id(input["input_id"]),
        source: Report.source(input, payload)
      )

    :ok
  end

  @doc false
  @spec report(map(), map()) :: String.t()
  defdelegate report(input, payload), to: Report, as: :node_report
end
