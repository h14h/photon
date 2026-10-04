defmodule Photon.Assistant.Transcript do
  @moduledoc """
  What the assistant page shows, as pure functions over the conversation's
  entries and its `{:live, ...}` events. `PhotonWeb.AssistantLive` drives
  them, the way `PhotonWeb.SessionLive` drives `Photon.NodeTranscript`.

    * which entries are shown (`shown?/1`); tool results aren't shown on
      their own but inside the assistant entry whose call they answer, so
      the page keeps an index of results by call ID and of calls by ID
      (`index/1`, `add_result/2`, `add_calls/2`)
    * node work a call left running, settled by the report that comes in
      later (`settle/3`)
    * the in-flight answer (`live/2`): text, reasoning and tool calls being
      prepared, or a retry notice, until the response is committed
    * a tool call's status as the page shows it (`action_status/2`)
    * Blip's mood (`mood/1`), and the outcome a batch of new entries is
      worth showing for a moment (`outcome/3`)
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [PhotonCore]

  alias Photon.Durable.Entry
  alias PhotonCore.Message

  @typedoc "Calls whose node work a later report settled, by call ID, with how it went."
  @type settled :: %{String.t() => :done | :error}

  @type index :: %{
          results: %{String.t() => map()},
          calls: %{String.t() => Entry.t()},
          settled: settled()
        }

  @type live :: %{
          text: String.t(),
          reasoning: String.t(),
          tools: %{non_neg_integer() => String.t()},
          retry: String.t() | nil
        }

  @typedoc "Blip's mood, as the avatar shows it."
  @type mood :: :idle | :thinking | :working | :done | :error

  @typedoc "What Blip's mood is made of right now."
  @type now :: %{
          outcome: :done | :error | nil,
          live: live() | nil,
          working: non_neg_integer(),
          busy: boolean()
        }

  @shown ~w(user assistant error reset)

  @doc "Whether an entry is shown in the conversation on its own."
  @spec shown?(Entry.t()) :: boolean()
  def shown?(%{kind: kind}), do: kind in @shown

  @doc "Whether a conversation has nothing to show yet (only tool results, or nothing)."
  @spec empty?([Entry.t()]) :: boolean()
  def empty?(entries), do: Enum.all?(entries, &(&1.kind == "tool_result"))

  @doc """
  Tool results by call ID, the assistant entries that made each call, and
  the calls whose node work a later report settled.
  """
  @spec index([Entry.t()]) :: index()
  def index(entries) do
    Enum.reduce(entries, %{results: %{}, calls: %{}, settled: %{}}, fn entry, index ->
      results = add_result(index.results, entry)
      {settled, _calls} = settle(index.settled, results, entry)
      %{results: results, calls: add_calls(index.calls, entry), settled: settled}
    end)
  end

  @doc "Adds a tool result entry to the results by call ID; other entries change nothing."
  @spec add_result(map(), Entry.t()) :: map()
  def add_result(results, %{kind: "tool_result"} = entry),
    do: Map.put(results, call_id(entry), entry.data)

  def add_result(results, _entry), do: results

  @doc "Adds an assistant entry's calls to the calls by ID; other entries change nothing."
  @spec add_calls(map(), Entry.t()) :: map()
  def add_calls(calls, %{kind: "assistant"} = entry) do
    Map.merge(calls, Map.new(Message.tool_calls(entry.data["message"]), &{&1["id"], entry}))
  end

  def add_calls(calls, _entry), do: calls

  @doc """
  Settles the node work a report answers. A call whose result said its work
  in the report's session was still running, and that no earlier report
  settled, ends the way the report says. Returns the settled calls and the
  IDs of the ones this report settled, so the page can show them again.

  Entries come in order, so a later call to the same session (a follow-up
  message) waits for the next report, not this one.
  """
  @spec settle(settled(), %{String.t() => map()}, Entry.t()) :: {settled(), [String.t()]}
  def settle(settled, results, %{
        kind: "user",
        data: %{"source" => %{"kind" => "node_report", "session_id" => session_id} = source}
      }) do
    outcome = if source["failed"] == true, do: :error, else: :done

    ids =
      for {call_id, data} <- results,
          running_in?(data, session_id),
          not Map.has_key?(settled, call_id),
          do: call_id

    {Map.merge(settled, Map.new(ids, &{&1, outcome})), ids}
  end

  def settle(settled, _results, _entry), do: {settled, []}

  defp running_in?(
         %{"status" => "ok", "details" => %{"status" => "running", "session_id" => session_id}},
         session_id
       ),
       do: true

  defp running_in?(_data, _session_id), do: false

  @doc "The call ID a tool result answers."
  @spec call_id(Entry.t()) :: String.t() | nil
  def call_id(%{kind: "tool_result"} = entry), do: entry.data["message"]["tool_call_id"]

  @doc "Folds a `{:live, ...}` event into the in-flight answer (nil before the first)."
  @spec live(live() | nil, map()) :: live()
  def live(_live, %{"type" => "start"}), do: %{text: "", reasoning: "", tools: %{}, retry: nil}
  def live(nil, event), do: live(live(nil, %{"type" => "start"}), event)

  def live(live, %{"type" => "text", "delta" => delta}),
    do: %{live | text: live.text <> delta, retry: nil}

  def live(live, %{"type" => "reasoning", "delta" => delta}),
    do: %{live | reasoning: live.reasoning <> delta}

  def live(live, %{"type" => "tool_call", "index" => index, "name" => name})
      when is_binary(name),
      do: %{live | tools: Map.put(live.tools, index, name)}

  def live(_live, %{"type" => "retry"} = event) do
    seconds = Float.round(event["delay_ms"] / 1000, 1)

    %{
      text: "",
      reasoning: "",
      tools: %{},
      retry: "The model didn't answer (#{event["message"]}). Trying again in #{seconds}s."
    }
  end

  def live(live, _event), do: live

  @doc """
  A tool call's status on the page, from its result entry's data (nil while
  it runs), the result's details, and how a later report settled its node
  work, if one did (`settle/3`): node work still running shows as running
  until a report settles it, failed node work as an error.
  """
  @spec action_status(map() | nil, map(), :done | :error | nil) ::
          :pending | :running | :done | :error | :stopped
  def action_status(result, details, settled \\ nil)

  def action_status(%{"status" => "ok"}, %{"status" => "running"}, settled)
      when settled in [:done, :error],
      do: settled

  def action_status(result, details, _settled), do: status(result, details)

  defp status(nil, _details), do: :pending
  defp status(%{"status" => "ok"}, %{"status" => "running"}), do: :running
  defp status(%{"status" => "ok"}, %{"status" => "failed"}), do: :error
  defp status(%{"status" => "ok"}, _details), do: :done
  defp status(%{"status" => "aborted"}, _details), do: :stopped
  defp status(_result, _details), do: :error

  @doc """
  Blip's mood. An outcome the page is holding (see `outcome/3`) shows first,
  so a finish or a failure gets its moment. Then: an answer in flight is
  thinking; node work the assistant started and is still running is
  working; a run between steps is thinking; otherwise idle.
  """
  @spec mood(now()) :: mood()
  def mood(%{outcome: outcome}) when outcome in [:done, :error], do: outcome
  def mood(%{live: live}) when is_map(live), do: :thinking
  def mood(%{working: working}) when working > 0, do: :working
  def mood(%{busy: true}), do: :thinking
  def mood(_now), do: :idle

  @doc """
  The outcome a batch of newly committed entries is worth showing, given
  whether a run was in flight before the batch and after it.

  Something that went wrong is `:error`: a failed run, a failed tool call,
  or a report of failed node work. A run the user stopped is nothing. A
  report of node work that went fine, or a run that finished, is `:done`.
  """
  @spec outcome([Entry.t()], boolean(), boolean()) :: :done | :error | nil
  def outcome(entries, was_busy, busy) do
    cond do
      Enum.any?(entries, &went_wrong?/1) -> :error
      Enum.any?(entries, &stopped?/1) -> nil
      Enum.any?(entries, &report?/1) -> :done
      was_busy and not busy -> :done
      true -> nil
    end
  end

  defp went_wrong?(%{kind: "error", data: data}), do: data["stopped"] != true

  defp went_wrong?(%{kind: "user", data: %{"source" => %{"kind" => "node_report"} = source}}),
    do: source["failed"] == true

  defp went_wrong?(%{kind: "tool_result", data: data}),
    do: action_status(data, data["details"] || %{}) == :error

  defp went_wrong?(_entry), do: false

  defp stopped?(%{kind: "error", data: data}), do: data["stopped"] == true
  defp stopped?(_entry), do: false

  defp report?(%{kind: "user", data: %{"source" => %{"kind" => "node_report"}}}), do: true
  defp report?(_entry), do: false
end
