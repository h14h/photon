defmodule Photon.Assistant.Transcript do
  @moduledoc """
  What the assistant page shows, as pure functions over the conversation's
  entries and its `{:live, ...}` events. `PhotonWeb.BlipLive` drives
  them.

    * which entries are shown (`shown?/1`); tool results aren't shown on
      their own but inside the assistant entry whose call they answer, so
      the page keeps an index of results by call ID and of calls by ID
      (`index/1`, `add_result/2`, `add_calls/2`). The index leaves image
      data out: the page loads each image by its result's entry ID
      (`image/2`), so the page's state and its renders stay small
    * the in-flight answer (`live/2`): text, reasoning, web searches and
      tool calls being prepared, or a retry notice, until the response is
      committed
    * the output of calls still running (`tool_output/2`): the last 8,000
      characters of each, kept apart from the in-flight answer, since a
      call runs after the answer that made it is committed
    * the web searches an answer ran (`searches/1`), and how each reads
      (`search_label/1`)
    * a tool call's status as the page shows it (`action_status/2`), and
      how a machine call's line reads (`machine_action/4`)
    * Blip's mood (`mood/1`), and the outcome a batch of new entries is
      worth showing for a moment (`outcome/3`)
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [PhotonCore]

  alias Photon.Durable.Entry
  alias PhotonCore.Message

  @type index :: %{results: %{String.t() => map()}, calls: %{String.t() => Entry.t()}}

  @type live :: %{
          text: String.t(),
          reasoning: String.t(),
          searches: [search()],
          # searches: newest first
          tools: %{non_neg_integer() => String.t()},
          retry: String.t() | nil
        }

  @typedoc "The tail of each running call's live output, by call ID."
  @type outputs :: %{String.t() => String.t()}

  @typedoc "A web search the model ran: its ID, and what it did (nil while it runs)."
  @type search :: %{id: String.t(), action: map() | nil}

  @typedoc "Blip's mood, as the avatar shows it."
  @type mood :: :idle | :thinking | :done | :error

  @typedoc "What Blip's mood is made of right now."
  @type now :: %{
          outcome: :done | :error | nil,
          live: live() | nil,
          busy: boolean()
        }

  @shown ~w(user assistant error reset)

  @image_types ~w(image/png image/jpeg image/gif image/webp)

  # How much of a running call's output the page keeps (section 3.4 of
  # docs/plans/step-1-machine-tools.md). The node sends at most 64 KB per
  # stream a second; the page shows the latest of it.
  @tail 8_000

  @doc "Whether an entry is shown in the conversation on its own."
  @spec shown?(Entry.t()) :: boolean()
  def shown?(%{kind: kind}), do: kind in @shown

  @doc "Whether a conversation has nothing to show yet (only tool results, or nothing)."
  @spec empty?([Entry.t()]) :: boolean()
  def empty?(entries), do: Enum.all?(entries, &(&1.kind == "tool_result"))

  @doc "Tool results by call ID, and the assistant entries that made each call."
  @spec index([Entry.t()]) :: index()
  def index(entries) do
    Enum.reduce(entries, %{results: %{}, calls: %{}}, fn entry, index ->
      %{results: add_result(index.results, entry), calls: add_calls(index.calls, entry)}
    end)
  end

  @doc """
  Adds a tool result entry to the results by call ID; other entries change
  nothing. The result keeps its entry's ID as `"entry_id"` and loses its
  images' data (`image/2` gives an image back from the entry).
  """
  @spec add_result(map(), Entry.t()) :: map()
  def add_result(results, %{kind: "tool_result"} = entry),
    do: Map.put(results, call_id(entry), shown_result(entry))

  def add_result(results, _entry), do: results

  defp shown_result(%{id: id, data: data}) do
    data =
      case data["message"] do
        %{"content" => parts} when is_list(parts) ->
          put_in(data, ["message", "content"], Enum.map(parts, &without_data/1))

        _other ->
          data
      end

    Map.put(data, "entry_id", id)
  end

  defp without_data(%{"type" => "image"} = part), do: Map.delete(part, "data")
  defp without_data(part), do: part

  @doc """
  The image at `index` among a tool result entry's images, decoded:
  `{:ok, mime, bytes}`. `:error` when there is no such image, its data
  isn't base64, or it isn't a PNG, JPEG, GIF or WebP image, the types
  `view_image` returns, so nothing else is served as one.
  """
  @spec image(Entry.t(), non_neg_integer()) :: {:ok, String.t(), binary()} | :error
  def image(%{kind: "tool_result", data: %{"message" => message}}, index) do
    with %{"mime" => mime, "data" => data} when mime in @image_types and is_binary(data) <-
           Enum.at(Message.images(message), index),
         {:ok, bytes} <- Base.decode64(data) do
      {:ok, mime, bytes}
    else
      _missing_or_bad -> :error
    end
  end

  def image(_entry, _index), do: :error

  @doc "Adds an assistant entry's calls to the calls by ID; other entries change nothing."
  @spec add_calls(map(), Entry.t()) :: map()
  def add_calls(calls, %{kind: "assistant"} = entry) do
    Map.merge(calls, Map.new(Message.tool_calls(entry.data["message"]), &{&1["id"], entry}))
  end

  def add_calls(calls, _entry), do: calls

  @doc "The call ID a tool result answers."
  @spec call_id(Entry.t()) :: String.t() | nil
  def call_id(%{kind: "tool_result"} = entry), do: entry.data["message"]["tool_call_id"]

  @doc "Folds a `{:live, ...}` event into the in-flight answer (nil before the first)."
  @spec live(live() | nil, map()) :: live()
  def live(_live, %{"type" => "start"}),
    do: %{text: "", reasoning: "", searches: [], tools: %{}, retry: nil}

  def live(nil, event), do: live(live(nil, %{"type" => "start"}), event)

  def live(live, %{"type" => "text", "delta" => delta}),
    do: %{live | text: live.text <> delta, retry: nil}

  def live(live, %{"type" => "reasoning", "delta" => delta}),
    do: %{live | reasoning: live.reasoning <> delta}

  def live(live, %{"type" => "tool_call", "index" => index, "name" => name})
      when is_binary(name),
      do: %{live | tools: Map.put(live.tools, index, name)}

  # A search starts (no action yet), then says what it did, in its place.
  # Newest first.
  def live(live, %{"type" => "web_search", "id" => id} = event) when is_binary(id) do
    search = %{id: id, action: event["action"]}

    searches =
      if Enum.any?(live.searches, &(&1.id == id)),
        do: Enum.map(live.searches, &if(&1.id == id, do: search, else: &1)),
        else: [search | live.searches]

    %{live | searches: searches}
  end

  def live(_live, %{"type" => "retry"} = event) do
    seconds = Float.round(event["delay_ms"] / 1000, 1)

    %{
      text: "",
      reasoning: "",
      searches: [],
      tools: %{},
      retry: "The model didn't answer (#{event["message"]}). Trying again in #{seconds}s."
    }
  end

  def live(live, _event), do: live

  @doc """
  Folds a `"tool_output"` live event into the running calls' output: each
  call keeps the last 8,000 characters of what it printed, both streams in
  the order they came. Other events change nothing.
  """
  @spec tool_output(outputs(), map()) :: outputs()
  def tool_output(outputs, %{"type" => "tool_output", "call_id" => call_id, "text" => text})
      when is_binary(call_id) and is_binary(text),
      do: Map.update(outputs, call_id, tail(text), &tail(&1 <> text))

  def tool_output(outputs, _event), do: outputs

  # At most @tail characters fit in @tail bytes, so most texts skip the count.
  defp tail(text) when byte_size(text) <= @tail, do: text

  defp tail(text) do
    case String.length(text) - @tail do
      over when over > 0 -> String.slice(text, over..-1//1)
      _short -> text
    end
  end

  @doc """
  The web searches a committed assistant message ran, in order: they're
  kept with its reasoning items, so they can be handed back to the model.
  """
  @spec searches(map()) :: [search()]
  def searches(%{"reasoning_items" => items}) when is_list(items) do
    for %{"type" => "web_search_call"} = item <- items,
        do: %{id: item["id"], action: item["action"]}
  end

  def searches(_message), do: []

  @doc """
  How a web search reads: what it looked for, or the page it read. A search
  still running (no action yet) reads as "Searching the web".
  """
  @spec search_label(map() | nil) :: String.t()
  def search_label(%{"type" => "search", "query" => query}) when is_binary(query) and query != "",
    do: "Searched the web for \u201c#{query}\u201d"

  def search_label(%{"type" => "open_page", "url" => url}) when is_binary(url),
    do: "Read #{short_url(url)}"

  def search_label(%{"type" => "find_in_page", "url" => url, "pattern" => pattern})
      when is_binary(url) and is_binary(pattern),
      do: "Looked in #{short_url(url)} for \u201c#{pattern}\u201d"

  def search_label(nil), do: "Searching the web"
  def search_label(_action), do: "Searched the web"

  # A URL without its scheme, "www." or query, and cut short if it runs long.
  defp short_url(url) do
    %URI{host: host, path: path} = URI.parse(url)

    short =
      String.replace_prefix(host || url, "www.", "") <> String.trim_trailing(path || "", "/")

    if String.length(short) > 60, do: String.slice(short, 0, 57) <> "...", else: short
  end

  @doc """
  A tool call's status on the page, from its result entry's data (nil while
  it runs) and the result's details. A machine operation that failed is an
  error, and one that was canceled is stopped.
  """
  @spec action_status(map() | nil, map()) :: :pending | :done | :error | :stopped
  def action_status(nil, _details), do: :pending
  def action_status(%{"status" => "ok"}, %{"status" => "failed"}), do: :error
  def action_status(%{"status" => "ok"}, %{"status" => "canceled"}), do: :stopped
  def action_status(%{"status" => "ok"}, _details), do: :done
  def action_status(%{"status" => "aborted"}, _details), do: :stopped
  def action_status(_result, _details), do: :error

  @doc """
  How a `shell` or `view_image` call's line reads, given its arguments, its
  result's details and its status (`action_status/2`): the verb, in the
  present while the call runs ("Running", "Looking at") and in the past
  once it has ended ("Ran", "Looked at"), the command or path, and the
  machine. The machine is always named, `local` too: from the arguments,
  or the result's details if the arguments have none (nil only when
  neither does).
  """
  @spec machine_action(String.t(), map(), map(), :pending | :done | :error | :stopped) ::
          %{verb: String.t(), subject: term(), machine: String.t() | nil}
  def machine_action("shell", args, details, status),
    do: machine_line(verb(status, "Running", "Ran"), args["command"], args, details)

  def machine_action("view_image", args, details, status),
    do: machine_line(verb(status, "Looking at", "Looked at"), args["path"], args, details)

  defp machine_line(verb, subject, args, details),
    do: %{verb: verb, subject: subject, machine: machine_name(args) || machine_name(details)}

  defp verb(:pending, running, _ran), do: running
  defp verb(_status, _running, ran), do: ran

  defp machine_name(%{"machine" => machine}) when is_binary(machine) and machine != "",
    do: machine

  defp machine_name(_map), do: nil

  @doc """
  Blip's mood. An outcome the page is holding (see `outcome/3`) shows first,
  so a finish or a failure gets its moment. Then: an answer in flight, or a
  run between steps, is thinking; otherwise idle.
  """
  @spec mood(now()) :: mood()
  def mood(%{outcome: outcome}) when outcome in [:done, :error], do: outcome
  def mood(%{live: live}) when is_map(live), do: :thinking
  def mood(%{busy: true}), do: :thinking
  def mood(_now), do: :idle

  @doc """
  The outcome a batch of newly committed entries is worth showing, given
  whether a run was in flight before the batch and after it.

  Something that went wrong is `:error`: a failed run or a failed tool
  call. A run the user stopped is nothing. A run that finished is `:done`.
  """
  @spec outcome([Entry.t()], boolean(), boolean()) :: :done | :error | nil
  def outcome(entries, was_busy, busy) do
    cond do
      Enum.any?(entries, &went_wrong?/1) -> :error
      Enum.any?(entries, &stopped?/1) -> nil
      was_busy and not busy -> :done
      true -> nil
    end
  end

  defp went_wrong?(%{kind: "error", data: data}), do: not quiet?(data)

  defp went_wrong?(%{kind: "tool_result", data: data}),
    do: action_status(data, data["details"] || %{}) == :error

  defp went_wrong?(_entry), do: false

  defp stopped?(%{kind: "error", data: data}), do: quiet?(data)
  defp stopped?(_entry), do: false

  @doc "Whether an error entry is a quiet one: a stopped run or a notice, not a failure."
  @spec quiet?(map()) :: boolean()
  def quiet?(data), do: data["stopped"] == true or data["notice"] == true
end
