defmodule Photon.Transcript do
  @moduledoc """
  What a conversation page shows, as pure functions over a durable
  conversation's entries and its `{:live, ...}` events. Blip's panel
  (`PhotonWeb.BlipLive`) drives them, and so does a thread's page.

    * which entries are shown (`shown?/1`), and what the user typed in a
      message (`typed/2`), without the note of the page Blip was told
      about or the note in front of an answer to a thread's question, and
      nothing for a thread's signal; tool results aren't shown on
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
      call runs after the answer that made it is committed; a stopped
      call keeps it after its result lands (`settle_output/3`)
    * the web searches an answer ran (`searches/1`), and how each reads
      (`search_label/1`)
    * a tool call's status as the page shows it (`action_status/2`), and
      how a machine call's line reads (`machine_action/4`)
    * Blip's mood (`mood/1`), and the outcome a batch of new entries is
      worth showing for a moment (`outcome/3`)
    * in Blip's panel: a signal message's lines (`signal_lines/1`), which
      entries show as a question's card (`question_card/1` for an ok
      `ask_owner` result, `escalation/1` for the hub's notice), and where
      each question put to the owner stands (`questions/3`), folded from
      the entries and the answers still queued in Blip's inbox
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

  @typedoc """
  A question Blip's conversation put to the owner, as its card shows it:
  open, answered (with the answer, when the conversation has it) or
  withdrawn, and the asking thread's title.
  """
  @type question :: %{
          status: :open | :answered | :withdrawn,
          answer: String.t() | nil,
          title: String.t() | nil
        }

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

  @doc """
  A user message's text as the user typed it, from the message (or its
  content) and the `"source"` it was submitted with:

    * a message sent with a page (`source["page"]`) starts with a note of
      that page for the model, so only its last text part was typed
    * the owner's answer to a thread's question (source kind `"answer"`)
      starts with a note that it went to the thread, so only its last
      text part was typed
    * a signal from a thread (source kind `"signal"`) is nothing the owner
      typed
    * any other message's text is all of it
  """
  @spec typed(Message.t() | Message.content(), map() | nil) :: String.t()
  def typed(%{"content" => content}, source), do: typed(content, source)
  def typed(_content, %{"kind" => "signal"}), do: ""

  def typed(parts, %{"kind" => "answer"}) when is_list(parts), do: last_text(parts)

  def typed(parts, %{"page" => page}) when is_list(parts) and is_map(page),
    do: last_text(parts)

  def typed(content, _source), do: Message.text_of(content)

  defp last_text(parts) do
    parts
    |> Enum.filter(&match?(%{"type" => "text", "text" => text} when is_binary(text), &1))
    |> List.last(%{"text" => ""})
    |> Map.fetch!("text")
  end

  @doc """
  The lines of a signal message (source kind `"signal"`), one per signal
  it carries, in order: each ref, and for a question the question as the
  thread asked it (its text part without the header line; nil for an
  update). Any other message has none.
  """
  @spec signal_lines(map()) :: [%{ref: map(), question: String.t() | nil}]
  def signal_lines(%{"message" => message, "source" => %{"kind" => "signal", "signals" => refs}})
      when is_list(refs) do
    parts =
      case message do
        %{"content" => parts} when is_list(parts) -> parts
        _other -> []
      end

    # A part for each ref, at the same index; a missing one is nil.
    refs
    |> Enum.zip(Stream.concat(parts, Stream.repeatedly(fn -> nil end)))
    |> Enum.flat_map(fn
      {%{} = ref, part} -> [%{ref: ref, question: signal_question(ref, part)}]
      {_not_a_ref, _part} -> []
    end)
  end

  def signal_lines(_data), do: []

  # A question's part is a header line, then the question.
  defp signal_question(%{"kind" => "question"}, %{"type" => "text", "text" => text})
       when is_binary(text) do
    case String.split(text, "\n", parts: 2) do
      [_header, question] -> String.trim(question)
      [_header_only] -> nil
    end
  end

  defp signal_question(_ref, _part), do: nil

  @doc """
  Whether a tool result is an `ask_owner` call that passed a question to
  the owner: its question's ID, so the call shows as the question's card.
  A refused call (an error result) is nil, and shows as an ordinary line.
  """
  @spec question_card(map() | nil) :: String.t() | nil
  def question_card(%{
        "name" => "ask_owner",
        "status" => "ok",
        "details" => %{"question_id" => id}
      })
      when is_binary(id),
      do: id

  def question_card(_result), do: nil

  @doc """
  Whether an entry is the hub's notice that it passed a question Blip
  didn't get to on to the owner: its question's ID. Such a notice shows
  as the question's card.
  """
  @spec escalation(Entry.t() | map()) :: String.t() | nil
  def escalation(%{
        kind: "error",
        data: %{"question_notice" => "escalated", "question_id" => id}
      })
      when is_binary(id),
      do: id

  def escalation(_entry), do: nil

  @doc """
  The questions Blip's conversation has put to the owner, by ID, folded
  from its entries and the submissions still queued in its inbox, on top
  of `known` (what an earlier fold gave):

    * an ok `ask_owner` result, or the hub's escalation notice, opens one
      (`:open`), with the thread's title
    * the owner's answer (a user entry with source kind `"answer"`), an
      ok `answer_question` result, or a queued `"answer"` submission
      answers it (`:answered`, with the answer when it is known)
    * a withdraw notice withdraws it (`:withdrawn`)

  A queued answer counts because the answer has already gone to the
  thread; its entry only comes when Blip's inbox gets to it. Answered and
  withdrawn are final: nothing later reopens or changes them.
  """
  @spec questions([Entry.t()], [map()], %{String.t() => question()}) :: %{
          String.t() => question()
        }
  def questions(entries, queued, known \\ %{}) do
    events = Enum.flat_map(entries, &question_events/1) ++ Enum.flat_map(queued, &queued_answer/1)
    Enum.reduce(events, known, &fold_question/2)
  end

  @doc """
  Folds what the questions' rows say into `questions` (from
  `questions/3`): one the conversation shows as open whose row is
  answered or withdrawn closes, so a card opened from a fresh read can't
  offer Answer for a question settled where the conversation doesn't
  show it. Rows are maps with `id`, `status`, `answer` and
  `thread_title`; open rows change nothing.
  """
  @spec close_from_rows(%{String.t() => question()}, [map()]) :: %{String.t() => question()}
  def close_from_rows(questions, rows) do
    rows
    |> Enum.flat_map(&row_event/1)
    |> Enum.reduce(questions, &fold_question/2)
  end

  defp row_event(%{id: id, status: "answered"} = row),
    do: [event(id, :answered, Map.get(row, :thread_title), text_or_nil(Map.get(row, :answer)))]

  defp row_event(%{id: id, status: "withdrawn"} = row),
    do: [event(id, :withdrawn, Map.get(row, :thread_title), nil)]

  defp row_event(_row), do: []

  defp question_events(%{kind: "tool_result", data: data}) do
    details = if is_map(data["details"]), do: data["details"], else: %{}

    cond do
      id = question_card(data) ->
        [event(id, :open, details["title"], nil)]

      answered_by_tool?(data, details) ->
        [
          event(
            details["question_id"],
            :answered,
            details["title"],
            text_or_nil(details["answer"])
          )
        ]

      true ->
        []
    end
  end

  defp question_events(%{kind: "error", data: %{"question_id" => id} = data})
       when is_binary(id) do
    case data["question_notice"] do
      "escalated" -> [event(id, :open, data["title"], nil)]
      "withdrawn" -> [event(id, :withdrawn, data["title"], nil)]
      _other -> []
    end
  end

  defp question_events(%{kind: "user", data: %{"source" => source} = data}),
    do: answer_event(data["message"], source)

  defp question_events(_entry), do: []

  defp answered_by_tool?(data, details),
    do:
      data["name"] == "answer_question" and data["status"] == "ok" and
        is_binary(details["question_id"])

  defp queued_answer(%{content: %{"parts" => parts, "source" => source}}),
    do: answer_event(parts, source)

  defp queued_answer(_submission), do: []

  defp answer_event(content, %{"kind" => "answer", "question_id" => id} = source)
       when is_binary(id),
       do: [event(id, :answered, source["title"], text_or_nil(typed(content, source)))]

  defp answer_event(_content, _source), do: []

  defp text_or_nil(text) when is_binary(text) and text != "", do: text
  defp text_or_nil(_text), do: nil

  # What one entry says about question `id`: where it stands afterwards.
  defp event(id, status, title, answer),
    do: {id, %{status: status, answer: answer, title: title}}

  defp fold_question({id, %{status: :open} = question}, questions),
    do: Map.put_new(questions, id, question)

  defp fold_question({id, question}, questions) do
    case questions[id] do
      %{status: done} when done in [:answered, :withdrawn] -> questions
      nil -> Map.put(questions, id, question)
      known -> Map.put(questions, id, %{question | title: question.title || known.title})
    end
  end

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

  @doc """
  The running calls' output once call `call_id` has its result (the
  result entry's data, as `add_result/2` keeps it): a call the user
  stopped keeps what it printed before the stop, since its result says
  only that it was stopped; any other call's output goes, as its result
  holds it.
  """
  @spec settle_output(outputs(), String.t() | nil, map() | nil) :: outputs()
  def settle_output(outputs, call_id, result) do
    if result && action_status(result, result["details"] || %{}) == :stopped,
      do: outputs,
      else: Map.delete(outputs, call_id)
  end

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
  present while the call runs ("Running", "Looking at"), in the past once
  it has ended ("Ran", "Looked at"), or saying it was stopped ("Stopped",
  "Stopped looking at"), the command or path, and the machine. The machine is always named, `local` too: from the arguments,
  or the result's details if the arguments have none (nil only when
  neither does).
  """
  @spec machine_action(String.t(), map(), map(), :pending | :done | :error | :stopped) ::
          %{verb: String.t(), subject: term(), machine: String.t() | nil}
  def machine_action("shell", args, details, status),
    do: machine_line(verb(status, "Running", "Ran", "Stopped"), args["command"], args, details)

  def machine_action("view_image", args, details, status) do
    verb = verb(status, "Looking at", "Looked at", "Stopped looking at")
    machine_line(verb, args["path"], args, details)
  end

  defp machine_line(verb, subject, args, details),
    do: %{verb: verb, subject: subject, machine: machine_name(args) || machine_name(details)}

  defp verb(:pending, running, _ran, _stopped), do: running
  defp verb(:stopped, _running, _ran, stopped), do: stopped
  defp verb(_status, _running, ran, _stopped), do: ran

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
