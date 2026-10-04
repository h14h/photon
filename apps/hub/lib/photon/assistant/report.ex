defmodule Photon.Assistant.Report do
  @moduledoc """
  How the assistant hears how node work ended, as pure functions of the
  work's description and the payload of its `"node_input:<id>"` signal
  (`"answer"`, `"failure"`, `"session_id"`).

  The same outcome reads two ways: as the watcher's report, a follow-up
  message that wakes the assistant (`node_report/2`), and as the result of
  the tool call that started the work, when the answer came within its wait
  (`tool_answer/2`). Only the header differs.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: []

  @doc "The signal a node input settles: what the tool and its watcher wait on."
  @spec signal_key(String.t()) :: String.t()
  def signal_key(input_id), do: "node_input:" <> input_id

  @doc "The request ID of the report for a node input, so it is posted once."
  @spec request_id(String.t()) :: String.t()
  def request_id(input_id), do: "report:" <> input_id

  @doc """
  The watcher's report: `input` has the work's `"node"`, `"title"` and
  `"session_id"`.
  """
  @spec node_report(map(), map()) :: String.t()
  def node_report(input, payload) do
    outcome(
      ~s{[Report from #{input["node"]}] "#{input["title"]}" (session #{input["session_id"]})},
      payload
    )
  end

  @doc "The tool call's result, when the answer came within its wait."
  @spec tool_answer(map(), map() | nil) :: String.t()
  def tool_answer(state, payload),
    do: outcome("#{state["node"]} (session #{state["session_id"]})", payload)

  defp outcome(header, %{"failure" => failure} = payload) when failure not in [nil, ""],
    do: "#{header} didn't finish: #{failure}" <> last_words(payload["answer"])

  defp outcome(header, %{"answer" => answer}) when answer not in [nil, ""],
    do: "#{header} finished:\n\n#{answer}"

  defp outcome(header, _payload), do: "#{header} finished without a summary."

  defp last_words(answer) when answer in [nil, ""], do: ""
  defp last_words(answer), do: "\n\nIts last words:\n\n" <> answer

  @doc "Whether the work failed."
  @spec failed?(map() | nil) :: boolean()
  def failed?(payload), do: payload["failure"] not in [nil, ""]

  @doc "The work's status as the tool call's details show it."
  @spec status(map() | nil) :: String.t()
  def status(payload), do: if(failed?(payload), do: "failed", else: "done")

  @doc "Where a report came from, stored with its submission for display."
  @spec source(map(), map()) :: map()
  def source(input, payload) do
    %{
      "kind" => "node_report",
      "node" => input["node"],
      "session_id" => input["session_id"],
      "title" => input["title"],
      "failed" => failed?(payload)
    }
  end

  @doc "The payload a watcher reports when it gave up before the node answered."
  @spec lost_track(String.t()) :: map()
  def lost_track(reason) do
    %{
      "failure" => "the hub lost track of it (#{reason}); check it with check_node_session",
      "answer" => nil
    }
  end

  @doc "The payload a watcher reports when the node hasn't answered within `wait_ms`."
  @spec no_answer(pos_integer()) :: map()
  def no_answer(wait_ms) do
    %{
      "failure" =>
        "no answer within #{div(wait_ms, 3_600_000)} hours, so the hub stopped waiting. " <>
          "It may still be running; check it with check_node_session",
      "answer" => nil
    }
  end

  @doc "The tool call's result while the work is still going."
  @spec still_running(map()) :: String.t()
  def still_running(state) do
    "Started on #{state["node"]} as session #{state["session_id"]} and still running. Its report will arrive in this conversation when it finishes; don't poll for it."
  end

  @doc "The tool call's result when the watcher has already posted the report."
  @spec already_reported(map()) :: String.t()
  def already_reported(state) do
    "#{state["node"]} (session #{state["session_id"]}) has finished; its report is in this conversation."
  end
end
