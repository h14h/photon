defmodule PhotonWeb.ConversationView do
  @moduledoc """
  The socket side of a durable conversation on screen, shared by Blip's
  panel (`PhotonWeb.BlipLive`) and a project's thread page: plain functions
  over a LiveView socket, not a process. The page reads the conversation
  through its context and hands what it read here; these functions only
  fold it into assigns and the `:entries` stream, through
  `Photon.Transcript`, so the fold lives in one place and the pages'
  callbacks stay short (rule 30).

  `mount_conversation/3` sets up the assigns `PhotonWeb.ConversationComponents`
  render from:

  - `results` and `calls`: each tool call's result, and the assistant entry
    that made each call, so a result can re-render its answer
    (`Photon.Transcript.index/1`);
  - `outputs`: the end of each running `shell` call's output, by call ID,
    from the `tool_output` live events (the hub stores none of it, so a page
    opened mid-command shows output from then on), dropped when the result
    comes, unless the call was stopped (then it stays, as all there is to
    show of what it did). A page opened later starts from what the
    machine sent of a stopped call's output when it stopped
    (`Photon.Machines.stopped_outputs/1`, the `outputs:` option);
  - `live` and `shown`: the in-flight answer, and its finished blocks;
  - `empty?`, `busy`, `queued`, and the composer's `mode` and `form`;
  - `questions`: where each question the conversation put to the owner
    stands (`Photon.Transcript.questions/3`), folded from the entries and
    the answers still queued, and `cards`, the entry that shows each
    one's card (the answer whose `ask_owner` call passed it on, or the
    hub's escalation notice), so a card re-renders when its question
    changes, as an answer re-renders when a call's result lands. Only
    Blip's conversation has any;
  - `titles`: the current title of each thread the conversation names
    (`Photon.Transcript.thread_ids/1`), by ID, which the components show
    in place of the title an entry recorded, and `mentions`, the entries
    that show each thread (a tool result's thread shows in the answer
    that made the call), so they re-render when its title changes. The
    page reads the titles: for the entries it mounts with (`titles:`),
    for threads new entries name (`untitled/2`) and for all of them when
    threads change (`thread_ids/1`), and hands them to `put_titles/2`;
  - the `:entries` stream of what the conversation shows.

  `apply_changes/4` folds a commit's `{:durable, ...}` changes in,
  `put_titles/2` threads' titles,
  `apply_live/2` a `{:live, ...}` event, and `reset_form/1` empties the
  composer after a send.
  """

  import Phoenix.Component, only: [assign: 2, update: 3, to_form: 2]
  import Phoenix.LiveView, only: [stream: 3, stream_configure: 3, stream_insert: 3]

  alias Phoenix.LiveView.Socket
  alias Photon.{Markdown, Transcript}

  @doc """
  Sets up a conversation's assigns and its `:entries` stream from its
  entries. Options: `busy:` and `queued:` (both required), `outputs:`,
  the output stopped calls printed, by call ID (none without it), `titles:`, the
  current titles of the threads the entries and the queued messages
  name (`Photon.Transcript.thread_ids/1`; none without it), and
  `dom_id:`, a function from an entry to its DOM ID (the stream's
  default, `entries-<id>`, without it).
  """
  @spec mount_conversation(Socket.t(), [map()], keyword()) :: Socket.t()
  def mount_conversation(socket, entries, opts) do
    %{results: results, calls: calls} = Transcript.index(entries)
    queued = Keyword.fetch!(opts, :queued)

    socket
    |> assign(
      results: results,
      calls: calls,
      titles: Keyword.get(opts, :titles, %{}),
      mentions: Enum.reduce(entries, %{}, &add_mentions(&2, &1, calls)),
      questions: Transcript.questions(entries, queued),
      cards: Enum.reduce(entries, %{}, &add_card(&2, &1, calls)),
      outputs: Keyword.get(opts, :outputs, %{}),
      empty?: Transcript.empty?(entries),
      live: nil,
      shown: nil,
      busy: Keyword.fetch!(opts, :busy),
      queued: queued,
      mode: "follow_up",
      form: blank_form()
    )
    |> configure(opts[:dom_id])
    |> stream(:entries, Enum.filter(entries, &Transcript.shown?/1))
  end

  @doc """
  Closes the questions the conversation shows as open whose rows say
  they are answered or withdrawn (`Photon.Transcript.close_from_rows/2`).
  The page reads `rows` for `open_questions/1` after mounting.
  """
  @spec close_questions(Socket.t(), [map()]) :: Socket.t()
  def close_questions(socket, rows),
    do: update(socket, :questions, &Transcript.close_from_rows(&1, rows))

  @doc "The IDs of the questions the conversation shows as open."
  @spec open_questions(Socket.t()) :: [String.t()]
  def open_questions(socket),
    do: for({id, %{status: :open}} <- socket.assigns.questions, do: id)

  @doc """
  The threads the conversation names (its entries and its queued
  messages), by ID, for the page to read their titles.
  """
  @spec thread_ids(Socket.t()) :: [String.t()]
  def thread_ids(socket) do
    queued = Enum.flat_map(socket.assigns.queued, &Transcript.thread_ids/1)
    Enum.uniq(Map.keys(socket.assigns.mentions) ++ queued)
  end

  @doc """
  The threads `items` (entries, queued messages) name whose titles the
  page hasn't read yet, for it to read before it folds them in.
  """
  @spec untitled(Socket.t(), [map()]) :: [String.t()]
  def untitled(socket, items) do
    items
    |> Enum.flat_map(&Transcript.thread_ids/1)
    |> Enum.uniq()
    |> Enum.reject(&Map.has_key?(socket.assigns.titles, &1))
  end

  @doc """
  Takes the titles the page read (`read`, by thread ID; nil for a thread
  that is gone), and re-renders the entries that show a thread whose
  title changed.
  """
  @spec put_titles(Socket.t(), Transcript.titles()) :: Socket.t()
  def put_titles(socket, read) do
    %{titles: titles, mentions: mentions} = socket.assigns
    changed = for {id, title} <- read, Map.get(titles, id) != title, do: id

    changed
    |> Enum.flat_map(&Map.values(Map.get(mentions, &1, %{})))
    |> Enum.uniq_by(& &1.id)
    |> Enum.reduce(assign(socket, titles: Map.merge(titles, read)), fn entry, socket ->
      stream_insert(socket, :entries, entry)
    end)
  end

  # The entry that shows each thread `entry` names: the entry itself, or
  # for a tool result the answer that made its call.
  defp add_mentions(mentions, entry, calls) do
    shown_in =
      cond do
        entry.kind == "tool_result" -> calls[Transcript.call_id(entry)]
        Transcript.shown?(entry) -> entry
        true -> nil
      end

    case {Transcript.thread_ids(entry), shown_in} do
      {[], _entry} ->
        mentions

      {_ids, nil} ->
        mentions

      {ids, shown_in} ->
        Enum.reduce(ids, mentions, fn id, mentions ->
          Map.update(
            mentions,
            id,
            %{shown_in.id => shown_in},
            &Map.put(&1, shown_in.id, shown_in)
          )
        end)
    end
  end

  defp configure(socket, nil), do: socket
  defp configure(socket, dom_id), do: stream_configure(socket, :entries, dom_id: dom_id)

  @doc """
  Folds a commit's changes in: its entries, then whether the conversation
  is busy and what waits in its inbox, both read by the caller after the
  commit. Once it isn't busy, there's no in-flight answer.
  """
  @spec apply_changes(Socket.t(), %{entries: [map()]}, boolean(), [map()]) :: Socket.t()
  def apply_changes(socket, changes, busy, queued) do
    socket = Enum.reduce(changes.entries, socket, &add_entry(&2, &1))
    socket = socket |> assign(queued: queued, busy: busy) |> fold_questions(changes.entries)
    if busy, do: socket, else: assign(socket, live: nil, shown: nil)
  end

  # A question that changed re-renders the entry that shows its card.
  defp fold_questions(socket, entries) do
    %{questions: known, queued: queued, cards: cards} = socket.assigns
    questions = Transcript.questions(entries, queued, known)

    questions
    |> Enum.filter(fn {id, question} -> known[id] != question and Map.has_key?(cards, id) end)
    |> Enum.reduce(assign(socket, questions: questions), fn {id, _question}, socket ->
      stream_insert(socket, :entries, cards[id])
    end)
  end

  # The entry that shows a question's card: the answer that made the
  # `ask_owner` call, or the escalation notice itself.
  defp add_card(cards, %{kind: "tool_result"} = entry, calls) do
    with id when is_binary(id) <- Transcript.question_card(entry.data),
         %{} = parent <- calls[Transcript.call_id(entry)] do
      Map.put(cards, id, parent)
    else
      _no_card -> cards
    end
  end

  defp add_card(cards, entry, _calls) do
    case Transcript.escalation(entry) do
      nil -> cards
      id -> Map.put(cards, id, entry)
    end
  end

  @doc """
  Folds a live event in. A running call's output is kept as a tail under
  it; output that comes after the result (or for no call on the page) has
  nowhere to go. Every other event is the in-flight answer.
  """
  @spec apply_live(Socket.t(), map()) :: Socket.t()
  def apply_live(socket, %{"type" => "tool_output", "call_id" => call_id} = event) do
    if Map.has_key?(socket.assigns.results, call_id) do
      socket
    else
      socket |> update(:outputs, &Transcript.tool_output(&1, event)) |> show_call(call_id)
    end
  end

  def apply_live(socket, event) do
    live = Transcript.live(socket.assigns.live, event)
    assign(socket, live: live, shown: shown(live))
  end

  @doc "Empties the composer and puts it back to sending after the current answer."
  @spec reset_form(Socket.t()) :: Socket.t()
  def reset_form(socket), do: assign(socket, form: blank_form(), mode: "follow_up")

  defp blank_form, do: to_form(%{"text" => ""}, as: :message)

  # What of the in-flight answer is shown: its finished blocks, so it comes
  # in a paragraph at a time (`Photon.Markdown.settled/1`). Its Markdown is
  # rendered again only when a block is added, not on every token.
  defp shown(live),
    do: %{text: Markdown.settled(live.text), reasoning: Markdown.settled(live.reasoning)}

  # A tool result re-renders the assistant entry whose call it answers, in
  # place of the output the call streamed while it ran (which a stopped
  # call keeps).
  defp add_entry(socket, %{kind: "tool_result"} = entry) do
    call_id = Transcript.call_id(entry)
    results = Transcript.add_result(socket.assigns.results, entry)

    socket
    |> assign(results: results)
    |> update(:cards, &add_card(&1, entry, socket.assigns.calls))
    |> update(:mentions, &add_mentions(&1, entry, socket.assigns.calls))
    |> update(:outputs, &Transcript.settle_output(&1, call_id, results[call_id]))
    |> show_call(call_id)
  end

  defp add_entry(socket, %{kind: "assistant"} = entry) do
    socket
    |> update(:calls, &Transcript.add_calls(&1, entry))
    |> assign(live: nil, shown: nil, empty?: false)
    |> stream_insert(:entries, entry)
  end

  defp add_entry(socket, entry) do
    if Transcript.shown?(entry),
      do:
        socket
        |> assign(empty?: false)
        |> update(:cards, &add_card(&1, entry, socket.assigns.calls))
        |> update(:mentions, &add_mentions(&1, entry, socket.assigns.calls))
        |> stream_insert(:entries, entry),
      else: socket
  end

  # Re-renders the assistant entry that made a call, if it's on the page.
  defp show_call(socket, call_id) do
    case socket.assigns.calls[call_id] do
      nil -> socket
      parent -> stream_insert(socket, :entries, parent)
    end
  end
end
