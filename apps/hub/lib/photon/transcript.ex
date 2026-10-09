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
    * which threads an entry or a queued message names (`thread_ids/1`),
      and the title a page shows for one (`title/3`): its current title,
      which the page reads by ID and keeps up to date, else the title the
      entry recorded when it was written (a thread's first title is the
      start of its first message until its run ends and it is named), so
      a renamed or newly named thread reads the same everywhere; a
      notice's words with the thread's current title (`notice_text/2`)
    * whether Blip's answer is `[nothing to tell]` (`nothing_to_tell?/1`),
      its reply to a digest or daily review with nothing worth the
      owner's attention, which makes no bubble and no activity row, and
      whether an entry is such an answer, which Blip's panel draws as
      nothing (`untold?/1`), along with what that run said on the way
      (`untold_run/2`)
    * a digest or daily review in Blip's panel (ambient mode): the ref a
      signal message carries (`ambient_ref/1`), its collapsed line
      (`ambient_heading/1`), the lines it opens to (`ambient_lines/3`,
      each thread under its current title), how many more it carried
      (`ambient_more/1`), and its chip while it waits in Blip's inbox
      (`ambient_chip/1`). A digest's and a review's items name their
      threads for `thread_ids/1` like any signal's
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
  withdrawn, and the asking thread's ID and title as the conversation
  recorded it.
  """
  @type question :: %{
          status: :open | :answered | :withdrawn,
          answer: String.t() | nil,
          title: String.t() | nil,
          thread_id: String.t() | nil
        }

  @typedoc """
  Threads' current titles by ID, as the page read them; nil for one it
  asked about that is gone.
  """
  @type titles :: %{optional(String.t()) => String.t() | nil}

  @typedoc """
  Where an ambient line's subject links: a thread's page, a project's, a
  context file's or a schedule's, by the project's slug; nil for none.
  """
  @type ambient_link ::
          {:thread, String.t(), String.t()}
          | {:project, String.t()}
          | {:file, String.t(), String.t()}
          | {:schedule, String.t(), String.t()}
          | nil

  @typedoc """
  One line of an opened digest or daily review: the item's kind, whether
  it was new to the owner (a review's lines all are), the project's name
  in front (nil when the subject is the project, or there is none), a
  word or two before the subject (`"context file"`), the subject (a
  thread's current title, a file's name...), where it links, and what
  happened.
  """
  @type ambient_line :: %{
          kind: String.t(),
          new?: boolean(),
          project: String.t() | nil,
          lead: String.t() | nil,
          subject: String.t(),
          link: ambient_link(),
          words: String.t()
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

  # How much of a running call's output the page keeps. The node sends at
  # most 64 KB per stream a second; the page shows the latest of it.
  @tail 8_000

  # What Blip answers to a digest or daily review with nothing worth
  # saying.
  @nothing_to_tell "[nothing to tell]"

  # The signal refs ambient mode posts.
  @ambient_kinds ~w(digest review)

  # How much of a schedule's prompt a digest line shows.
  @prompt_limit 80

  @doc """
  Whether `text` is Blip's `[nothing to tell]`: the text trimmed,
  lowercased and without a trailing `.` is exactly that. Anything that
  isn't text is false.
  """
  @spec nothing_to_tell?(term()) :: boolean()
  def nothing_to_tell?(text) when is_binary(text),
    do:
      text |> String.trim() |> String.downcase() |> String.replace_suffix(".", "") ==
        @nothing_to_tell

  def nothing_to_tell?(_text), do: false

  @doc """
  Whether an entry is Blip's `[nothing to tell]` answer: an assistant
  entry whose text is that (`nothing_to_tell?/1`) and that makes no tool
  call. Blip's panel draws nothing for it.
  """
  @spec untold?(Entry.t() | map()) :: boolean()
  def untold?(%{kind: "assistant", data: %{"message" => message}}),
    do: Message.tool_calls(message) == [] and nothing_to_tell?(Message.text_of(message))

  def untold?(_entry), do: false

  @typedoc """
  What `untold_run/2` carries from one batch to the next: whether the
  run in progress is a digest's or review's alone (`ambient?`), the IDs
  of the answers it made on the way, and whether the last run ended.
  """
  @type untold_state :: %{ambient?: boolean(), ids: [String.t()], ended?: boolean()}

  @doc "The state before any entry, for `untold_run/2`: no run in progress."
  @spec untold_initial() :: untold_state()
  def untold_initial, do: %{ambient?: false, ids: [], ended?: true}

  @doc """
  What else Blip's panel hides in a batch of entries that follows the
  batches `state` has seen: when a digest's or daily review's run that
  nobody else wrote into ends `[nothing to tell]` (`untold?/1`), the
  answers it made on the way (their text and tool calls, with the
  results drawn inside them). The owner wasn't told anything, so the
  panel leaves only the digest's own line, as Blip's later requests
  leave the whole run out. Returns those answers' IDs, which may be
  from earlier batches, and the state for the next batch.
  """
  @spec untold_run([Entry.t() | map()], untold_state()) :: {[String.t()], untold_state()}
  def untold_run(entries, state), do: Enum.flat_map_reduce(entries, state, &untold_step/2)

  # A user entry starts the next run, or joins the one in progress (an
  # owner's steer), which is then no longer the digest's alone.
  defp untold_step(%{kind: "user", data: data}, %{ended?: true}),
    do: {[], %{ambient?: ambient_ref(data["source"]) != nil, ids: [], ended?: false}}

  defp untold_step(%{kind: "user"}, state), do: {[], %{state | ambient?: false}}

  defp untold_step(%{kind: "assistant", id: id, data: %{"message" => message}} = entry, state) do
    cond do
      Message.tool_calls(message) != [] -> {[], %{state | ids: [id | state.ids]}}
      state.ambient? and untold?(entry) -> {state.ids, %{state | ids: [], ended?: true}}
      true -> {[], %{state | ids: [], ended?: true}}
    end
  end

  # The hub's notices about questions come between runs' entries; any
  # other error ends the run.
  defp untold_step(%{kind: "error", data: %{"notice" => true}}, state), do: {[], state}
  defp untold_step(%{kind: "error"}, state), do: {[], %{state | ids: [], ended?: true}}
  defp untold_step(_entry, state), do: {[], state}

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
  The threads an entry names, by ID, for the page to read their titles:
  a signal message's threads, the thread an answer went to, the thread a
  tool result's details name (shown in the answer that made the call),
  and the thread of a question's notice. A queued submission names the
  threads of its source the same way. Anything else names none.
  """
  @spec thread_ids(Entry.t() | map()) :: [String.t()]
  def thread_ids(%{kind: "user", data: %{"source" => source}}), do: source_threads(source)

  def thread_ids(%{kind: "tool_result", data: %{"details" => %{"thread_id" => id}}})
      when is_binary(id),
      do: [id]

  def thread_ids(%{kind: "error", data: %{"thread_id" => id}}) when is_binary(id), do: [id]
  def thread_ids(%{content: %{"source" => source}}), do: source_threads(source)
  def thread_ids(_entry), do: []

  defp source_threads(%{"kind" => "signal", "signals" => refs}) when is_list(refs),
    do: refs |> Enum.flat_map(&ref_threads/1) |> Enum.uniq()

  defp source_threads(%{"kind" => "answer", "thread_id" => id}) when is_binary(id), do: [id]
  defp source_threads(_source), do: []

  # A digest's or review's threads are its items' (a file's writer
  # included, when a thread wrote it); any other ref's is its own.
  defp ref_threads(%{"kind" => kind, "items" => items}) when kind in @ambient_kinds,
    do: if(is_list(items), do: Enum.flat_map(items, &item_threads/1), else: [])

  defp ref_threads(%{"thread_id" => id}) when is_binary(id), do: [id]
  defp ref_threads(_ref), do: []

  defp item_threads(%{} = item) do
    for id <- [item["thread_id"], item["writer"]], thread_id?(id), do: id
  end

  defp item_threads(_item), do: []

  defp thread_id?(id), do: is_binary(id) and String.starts_with?(id, "c_")

  @doc """
  The title a page shows for thread `id`: its current title from
  `titles`, else `stored`, the title the entry recorded (nil when that
  isn't text either).
  """
  @spec title(titles(), term(), term()) :: String.t() | nil
  def title(titles, id, stored) do
    case is_binary(id) and Map.get(titles, id) do
      title when is_binary(title) -> title
      _unknown when is_binary(stored) -> stored
      _unknown -> nil
    end
  end

  @doc """
  A notice's words (an error entry's `"message"`), with the thread it
  names in quotes under its current title from `titles` rather than the
  title it had when the notice was written (`"title"`).
  """
  @spec notice_text(map(), titles()) :: String.t()
  def notice_text(%{"message" => message} = data, titles) when is_binary(message) do
    old = data["title"]

    case title(titles, data["thread_id"], old) do
      new when is_binary(old) and old != "" and new != old ->
        String.replace(message, ~s("#{old}"), ~s("#{new}"))

      _same ->
        message
    end
  end

  def notice_text(_data, _titles), do: ""

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
  The digest or daily review ref a signal message's source carries (ref
  kind `"digest"` or `"review"`), or nil for any other source. Such a
  message carries only that ref: a digest or review never merges with
  other signals.
  """
  @spec ambient_ref(term()) :: map() | nil
  def ambient_ref(%{"kind" => "signal", "signals" => refs}) when is_list(refs),
    do: Enum.find(refs, &match?(%{"kind" => kind} when kind in @ambient_kinds, &1))

  def ambient_ref(_source), do: nil

  @doc ~S"""
  A digest's or daily review's collapsed line: "Digest: 3 new, 6 you've
  seen" (counting the items it shows and the ones it had no room for;
  the second count is what its opened list calls "Already seen, or done
  by you"), or "Daily review: 2 threads".
  """
  @spec ambient_heading(map()) :: String.t()
  def ambient_heading(%{"kind" => "digest"} = ref) do
    case digest_counts(ref) do
      {0, 0} -> "Digest"
      {new, 0} -> "Digest: #{new} new"
      {0, seen} -> "Digest: #{seen} you've seen"
      {new, seen} -> "Digest: #{new} new, #{seen} you've seen"
    end
  end

  def ambient_heading(%{"kind" => "review"} = ref),
    do: "Daily review: " <> count(review_count(ref), "thread")

  def ambient_heading(_ref), do: "Digest"

  @doc ~S"""
  A digest's or daily review's chip while it waits in Blip's inbox:
  "Digest: 3 new changes" or "Daily review: 2 threads". It names no
  thread.
  """
  @spec ambient_chip(map()) :: String.t()
  def ambient_chip(%{"kind" => "digest"} = ref) do
    case digest_counts(ref) do
      {0, 0} -> "Digest"
      {0, seen} -> "Digest: " <> count(seen, "change") <> " you've seen"
      {new, _smaller} -> "Digest: " <> count(new, "new change")
    end
  end

  def ambient_chip(ref), do: ambient_heading(ref)

  @doc ~S"""
  How many items a digest or daily review carried beyond the ones it
  lists, in words ("And 4 more."), or nil when it lists them all.
  """
  @spec ambient_more(map()) :: String.t() | nil
  def ambient_more(%{} = ref) do
    case amount(ref["more"]) + amount(ref["more_smaller"]) do
      0 -> nil
      more -> "And #{more} more."
    end
  end

  def ambient_more(_ref), do: nil

  # New and smaller changes, the listed items and the ones past the cut.
  defp digest_counts(ref) do
    items = if is_list(ref["items"]), do: ref["items"], else: []
    new = Enum.count(items, &match?(%{"new" => true}, &1))

    {new + amount(ref["more"]), Enum.count(items, &is_map/1) - new + amount(ref["more_smaller"])}
  end

  defp review_count(ref) do
    items = if is_list(ref["items"]), do: ref["items"], else: []
    Enum.count(items, &is_map/1) + amount(ref["more"])
  end

  defp amount(n) when is_integer(n) and n > 0, do: n
  defp amount(_n), do: 0

  @doc """
  The lines an opened digest or daily review shows, one per item it
  lists, in order (see `t:ambient_line/0`). Each thread is named by its
  current title in `titles`, else the title the digest recorded
  (`title/3`), so one written before the thread was named reads with its
  name. `at` is when the message was posted: a review's lines say how
  long each thread had sat as of then ("stopped 4 days ago"), or just
  its state without it. Items that aren't maps, and any other ref, give
  none.
  """
  @spec ambient_lines(term(), titles(), DateTime.t() | nil) :: [ambient_line()]
  def ambient_lines(ref, titles, at \\ nil)

  def ambient_lines(%{"kind" => kind, "items" => items}, titles, at)
      when kind in @ambient_kinds and is_list(items),
      do: for(%{} = item <- items, do: ambient_line(kind, item, titles, at))

  def ambient_lines(_ref, _titles, _at), do: []

  defp ambient_line("digest", item, titles, _at) do
    Map.merge(
      %{
        kind: text_or(item["kind"], "change"),
        new?: item["new"] == true,
        project: text_or_nil(item["project"]),
        lead: nil
      },
      digest_line(item["kind"], item, titles)
    )
  end

  defp ambient_line("review", item, titles, at) do
    item
    |> thread_line(titles, review_words(item["state"], since(item["since"]), at))
    |> Map.merge(%{
      kind: text_or(item["state"], "quiet"),
      new?: true,
      project: text_or_nil(item["project"]),
      lead: nil
    })
  end

  # What a digest item's line says, past its kind and project: its subject,
  # where it links and what happened, and a lead before the subject (or no
  # project in front, when the subject is the project).
  defp digest_line("finished", %{"new" => true} = item, titles),
    do: thread_line(item, titles, "finished")

  defp digest_line("finished", item, titles),
    do: thread_line(item, titles, "finished; you've seen it")

  defp digest_line("thread_started", item, titles), do: thread_line(item, titles, "started")
  defp digest_line("resolved", item, titles), do: thread_line(item, titles, "resolved")

  defp digest_line("schedule_stopped", item, _titles) do
    subject =
      case item["prompt"] |> one_line() |> cut(@prompt_limit) do
        "" -> text_or(item["schedule_id"], "without a prompt")
        prompt -> ~s("#{prompt}")
      end

    %{
      lead: if(is_binary(item["project"]), do: "schedule", else: "Blip's schedule"),
      subject: subject,
      link: if(is_binary(item["slug"]), do: link(:schedule, item["slug"], item["schedule_id"])),
      words: "stopped after an error"
    }
  end

  defp digest_line("file_written", item, titles) do
    deleted? = item["deleted"] == true

    %{
      lead: "context file",
      subject: text_or(item["name"], "a file"),
      link: if(not deleted?, do: link(:file, item["slug"], item["name"])),
      words: if(deleted?, do: "deleted", else: "written") <> writer(item, titles)
    }
  end

  defp digest_line("project_created", item, _titles), do: project_line(item, "started")

  defp digest_line("purpose_changed", item, _titles),
    do: project_line(item, "name or Purpose edited")

  defp digest_line(_kind, item, titles), do: thread_line(item, titles, "changed")

  defp thread_line(item, titles, words),
    do: %{subject: thread_subject(item, titles), link: thread_link(item), words: words}

  defp project_line(item, words),
    do: %{
      project: nil,
      lead: "project",
      subject: text_or(item["project"], "A project"),
      link: project_link(item),
      words: words
    }

  # Who wrote a file: the owner, a thread by its current title, or nobody named.
  defp writer(%{"writer" => "user"}, _titles), do: " by you"

  defp writer(%{"writer" => writer} = item, titles) when is_binary(writer) do
    case title(titles, writer, item["writer_title"]) do
      title when is_binary(title) and title != "" -> ~s( by "#{title}")
      _untitled -> " by a thread"
    end
  end

  defp writer(_item, _titles), do: ""

  defp thread_subject(item, titles) do
    case title(titles, item["thread_id"], item["title"]) do
      title when is_binary(title) and title != "" -> title
      _untitled -> "A thread"
    end
  end

  defp thread_link(item), do: link(:thread, item["slug"], item["thread_id"])

  defp project_link(%{"slug" => slug}) when is_binary(slug), do: {:project, slug}
  defp project_link(_item), do: nil

  defp link(kind, slug, id) when is_binary(slug) and is_binary(id), do: {kind, slug, id}
  defp link(_kind, _slug, _id), do: nil

  # A review's words: the thread's state, and how long it had sat when the
  # review was posted.
  defp review_words("failed", since, at), do: "failed" <> ago(since, at)
  defp review_words("waiting", since, at), do: "waiting on you" <> sat_for(since, at)
  defp review_words(_quiet, since, at), do: "stopped" <> ago(since, at)

  defp ago(%DateTime{} = since, %DateTime{} = at), do: " #{duration(since, at)} ago"
  defp ago(_since, _at), do: ""

  defp sat_for(%DateTime{} = since, %DateTime{} = at), do: " for #{duration(since, at)}"
  defp sat_for(_since, _at), do: ""

  # Whole days, else whole hours, else whole minutes (at least one).
  defp duration(since, at) do
    case max(DateTime.diff(at, since, :second), 0) do
      seconds when seconds >= 86_400 -> count(div(seconds, 86_400), "day")
      seconds when seconds >= 3_600 -> count(div(seconds, 3_600), "hour")
      seconds -> count(max(div(seconds, 60), 1), "minute")
    end
  end

  defp since(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, since, _offset} -> since
      _error -> nil
    end
  end

  defp since(_text), do: nil

  defp count(1, word), do: "1 #{word}"
  defp count(n, word), do: "#{n} #{word}s"

  defp text_or(text, _default) when is_binary(text) and text != "", do: text
  defp text_or(_text, default), do: default

  defp one_line(text) when is_binary(text),
    do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  defp one_line(_text), do: ""

  defp cut(text, limit) do
    if String.length(text) > limit, do: String.slice(text, 0, limit - 3) <> "...", else: text
  end

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
    do: [event(id, :answered, row_thread(row), text_or_nil(Map.get(row, :answer)))]

  defp row_event(%{id: id, status: "withdrawn"} = row),
    do: [event(id, :withdrawn, row_thread(row), nil)]

  defp row_event(_row), do: []

  defp row_thread(row),
    do: %{"thread_id" => Map.get(row, :thread_id), "title" => Map.get(row, :thread_title)}

  defp question_events(%{kind: "tool_result", data: data}) do
    details = if is_map(data["details"]), do: data["details"], else: %{}

    cond do
      id = question_card(data) ->
        [event(id, :open, details, nil)]

      answered_by_tool?(data, details) ->
        [
          event(
            details["question_id"],
            :answered,
            details,
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
      "escalated" -> [event(id, :open, data, nil)]
      "withdrawn" -> [event(id, :withdrawn, data, nil)]
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
       do: [event(id, :answered, source, text_or_nil(typed(content, source)))]

  defp answer_event(_content, _source), do: []

  defp text_or_nil(text) when is_binary(text) and text != "", do: text
  defp text_or_nil(_text), do: nil

  # What one entry says about question `id`: where it stands afterwards,
  # and its thread from `place` (a map with `"thread_id"` and `"title"`).
  defp event(id, status, place, answer),
    do:
      {id,
       %{
         status: status,
         answer: answer,
         title: text_or_nil(place["title"]),
         thread_id: text_or_nil(place["thread_id"])
       }}

  defp fold_question({id, %{status: :open} = question}, questions),
    do: Map.put_new(questions, id, question)

  defp fold_question({id, question}, questions) do
    case questions[id] do
      %{status: done} when done in [:answered, :withdrawn] ->
        questions

      nil ->
        Map.put(questions, id, question)

      known ->
        Map.put(questions, id, %{
          question
          | title: question.title || known.title,
            thread_id: question.thread_id || known.thread_id
        })
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
