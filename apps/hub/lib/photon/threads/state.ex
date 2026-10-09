defmodule Photon.Threads.State do
  @moduledoc """
  A thread's state, worked out by code from facts the hub stores: never by a
  model, and never stored itself (rule 15).

  `of/3` gives the first state whose rule holds:

    1. a question is with the owner: `:waiting`
    2. a run is in progress and its question is with Blip: `:asking`
    3. a run is in progress: `:running`
    4. the owner resolved it: `:idle`
    5. its last run failed: `:failed`
    6. its last run finished asking the user something: `:waiting`
    7. its last run finished and the owner hasn't looked since: `:unread`
    8. its last run was stopped (or never recorded an end), and nothing
       has happened for `quiet_after` seconds: `:quiet`
    9. otherwise `:idle`

  Quiet is for work left unfinished: a finished run the owner has read is
  done, however old.

  `asks?/1` and `note/2` are total (any term in, a value out), since they
  run inside the harness's settle hook.
  """

  # Functional core: no processes, no I/O. The time comes in as an argument.
  use Boundary, top_level?: true, type: :strict, deps: [Photon.Text]

  alias Photon.Text

  @typedoc "A thread's state."
  @type t :: :waiting | :asking | :running | :failed | :unread | :quiet | :idle

  @typedoc """
  What a state is worked out from: `busy?` means a run is in progress (from
  the durable harness); `question` is `:with_owner` when any open
  `ask_blip` question is with the owner, else `:with_blip` when one is
  asked, else nil; `active_at` is the thread's last message; the rest are
  as stored on the thread.
  """
  @type facts :: %{
          required(:busy?) => boolean(),
          required(:question) => nil | :with_blip | :with_owner,
          required(:last_run_status) => nil | String.t(),
          required(:last_run_ended_at) => DateTime.t() | nil,
          required(:last_run_asked) => boolean(),
          required(:active_at) => DateTime.t() | nil,
          required(:seen_at) => DateTime.t() | nil,
          required(:resolved_at) => DateTime.t() | nil,
          optional(atom()) => term()
        }

  @typedoc "`quiet_after`: how many seconds without activity make a stopped thread quiet."
  @type opts :: %{quiet_after: non_neg_integer()}

  @typedoc """
  A thread on the board as `sections/1` reads it: `thread` is its row and
  `questions` its open questions (maps with `id`, `status`, `inserted_at`
  and `passed_at`). Any other keys go along with it.
  """
  @type entry :: %{
          required(:state) => t(),
          required(:thread) => map(),
          required(:questions) => [map()],
          optional(atom()) => term()
        }

  @typedoc """
  A row of the home page's Waiting on you list: a question with the owner
  (`id` is the question's) or a thread whose last answer asked (`id` is
  the thread's), with its board entry.
  """
  @type waiting_row ::
          %{kind: :question, id: String.t(), question: map(), entry: entry()}
          | %{kind: :thread, id: String.t(), entry: entry()}

  @typedoc "A section cut to its limit: the rows shown and how many more there are."
  @type cut :: %{rows: [entry()], more: non_neg_integer()}

  @typedoc "The home page's sections (`sections/1`)."
  @type sections :: %{
          needs_you: non_neg_integer(),
          waiting: [waiting_row()],
          failed: cut(),
          unread: cut(),
          running: [entry()],
          quiet: cut()
        }

  # The longest note stored with a run's end.
  @note_limit 280

  # How many rows the home page's cut sections show.
  @failed_limit 20
  @unread_limit 20
  @quiet_limit 10

  @doc "The thread's state at `now`, by the first rule of the moduledoc's list that holds."
  @spec of(facts(), DateTime.t(), opts()) :: t()
  def of(facts, now, opts) do
    case live(facts) do
      nil -> settled(facts, now, opts)
      state -> state
    end
  end

  # Rules 1 to 3: a question with the owner, or a run in progress.
  defp live(%{question: :with_owner}), do: :waiting
  defp live(%{busy?: true, question: :with_blip}), do: :asking
  defp live(%{busy?: true}), do: :running
  defp live(_facts), do: nil

  # Rules 4 to 9: no run in progress, so the last run's end decides.
  defp settled(%{resolved_at: %DateTime{}}, _now, _opts), do: :idle
  defp settled(%{last_run_status: "failed"}, _now, _opts), do: :failed
  defp settled(%{last_run_status: "done", last_run_asked: true}, _now, _opts), do: :waiting

  defp settled(%{last_run_status: "done"} = facts, _now, _opts),
    do: if(unseen?(facts), do: :unread, else: :idle)

  defp settled(%{last_run_status: status} = facts, now, opts) when status in [nil, "stopped"],
    do: if(quiet?(facts, now, opts), do: :quiet, else: :idle)

  defp settled(_facts, _now, _opts), do: :idle

  @doc """
  Whether the thread's last run finished (`"done"`) and the owner hasn't
  had its page open since. A thread row or a facts map both work.
  """
  @spec unseen?(map()) :: boolean()
  def unseen?(%{last_run_status: "done", seen_at: nil}), do: true

  def unseen?(%{last_run_status: "done", seen_at: %DateTime{} = seen, last_run_ended_at: ended})
      when is_struct(ended, DateTime),
      do: DateTime.before?(seen, ended)

  def unseen?(_facts), do: false

  defp quiet?(facts, now, %{quiet_after: quiet_after}) do
    case last_activity(facts) do
      nil -> false
      at -> DateTime.diff(now, at, :second) > quiet_after
    end
  end

  @doc """
  When anything last happened on a thread: the later of its last message
  and its last run's end, or nil. A thread row or a facts map both work.
  """
  @spec last_activity(map()) :: DateTime.t() | nil
  def last_activity(facts) do
    [Map.get(facts, :active_at), Map.get(facts, :last_run_ended_at)]
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> Enum.max(DateTime, fn -> nil end)
  end

  @doc """
  The board's entries grouped into the home page's sections:

    * `waiting`: every open question with the owner, and every thread
      waiting on the owner without one, the longest wait first. All of
      them.
    * `failed` and `unread`: the most recent run end first, at most
      #{@failed_limit} each.
    * `running`: the threads at work, the longest running first, then
      those waiting on Blip, the oldest question first. All of them.
    * `quiet`: the oldest activity first, at most #{@quiet_limit}.

  `needs_you` counts the threads that are waiting, failed or unread,
  each once however many questions it has, as the sidebar's badge does.
  Idle threads are in no section.
  """
  @spec sections([entry()]) :: sections()
  def sections(board) do
    by_state = Enum.group_by(board, & &1.state)
    failed = in_state(by_state, :failed)
    unread = in_state(by_state, :unread)
    waiting = in_state(by_state, :waiting)

    %{
      needs_you: length(waiting) + length(failed) + length(unread),
      waiting: waiting_rows(board),
      failed: newest_first(failed, @failed_limit),
      unread: newest_first(unread, @unread_limit),
      running: running_rows(by_state),
      quiet: quiet_rows(by_state)
    }
  end

  defp in_state(by_state, state), do: Map.get(by_state, state, [])

  defp newest_first(entries, limit), do: entries |> sort_by(&ended_at/1, :desc) |> cut(limit)

  defp quiet_rows(by_state) do
    by_state
    |> in_state(:quiet)
    |> sort_by(&last_activity(&1.thread), :asc)
    |> cut(@quiet_limit)
  end

  defp running_rows(by_state) do
    working = by_state |> in_state(:running) |> sort_by(&active_at/1, :asc)
    asking = by_state |> in_state(:asking) |> sort_by(&first_asked_at/1, :asc)
    working ++ asking
  end

  defp waiting_rows(board) do
    questions =
      for entry <- board,
          question <- entry.questions,
          question.status == "with_owner",
          do: %{kind: :question, id: question.id, question: question, entry: entry}

    asking =
      for %{state: :waiting} = entry <- board,
          not Enum.any?(entry.questions, &(&1.status == "with_owner")),
          do: %{kind: :thread, id: entry.thread.id, entry: entry}

    sort_by(questions ++ asking, &waiting_since/1, :asc)
  end

  defp waiting_since(%{kind: :question, question: question}),
    do: Map.get(question, :passed_at) || Map.get(question, :inserted_at)

  defp waiting_since(%{kind: :thread, entry: entry}),
    do: ended_at(entry) || active_at(entry)

  defp ended_at(entry), do: Map.get(entry.thread, :last_run_ended_at)
  defp active_at(entry), do: Map.get(entry.thread, :active_at)

  defp first_asked_at(entry) do
    entry.questions
    |> Enum.filter(&(&1.status == "asked"))
    |> Enum.map(&Map.get(&1, :inserted_at))
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> Enum.min(DateTime, fn -> nil end)
  end

  # Sorted by a time, where one not known counts as the oldest;
  # `Enum.sort_by/3` is stable, so equal times keep the board's order.
  defp sort_by(rows, time, order) do
    Enum.sort_by(rows, &sort_key(time.(&1)), order)
  end

  defp sort_key(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
  defp sort_key(_unknown), do: 0

  defp cut(rows, limit) do
    {shown, rest} = Enum.split(rows, limit)
    %{rows: shown, more: length(rest)}
  end

  @doc """
  The words for a state, as every page and Blip's tools show it, so they
  read the same everywhere.
  """
  @spec label(t(), map()) :: String.t()
  def label(:waiting, _facts), do: "Waiting on you"
  def label(:asking, _facts), do: "Asking Blip"
  def label(:running, _facts), do: "Running"
  def label(:failed, _facts), do: "Failed"
  def label(:unread, _facts), do: "Finished"
  def label(:quiet, _facts), do: "Quiet"
  def label(:idle, %{resolved_at: %DateTime{}}), do: "Resolved"
  def label(:idle, %{last_run_status: "done"}), do: "Done"
  def label(:idle, _facts), do: "Idle"

  @doc """
  Whether an answer ends by asking the user something: its last paragraph
  that has words in it, past any fenced code block at the end and without
  trailing whitespace, `*`, `_`, backticks, `)` and quotes, ends in `?`.
  A heuristic on purpose, since no model reads the answer. False for
  anything that isn't text.
  """
  @spec asks?(term()) :: boolean()
  def asks?(text) when is_binary(text) do
    case text |> paragraphs() |> List.last() do
      nil ->
        false

      last ->
        last
        |> String.replace(~r/[\s*_`)"'\x{201C}\x{201D}\x{2018}\x{2019}]+\z/u, "")
        |> String.ends_with?("?")
    end
  end

  def asks?(_not_text), do: false

  @doc """
  The note stored with a run's end: for `"done"`, the answer's first
  paragraph, or its last when it asks (`asks?/1`); for `"failed"`, the
  reason; cut to #{@note_limit} characters. Nil for a stopped run, and
  for no text.
  """
  @spec note(term(), term()) :: String.t() | nil
  def note("done", text) when is_binary(text) do
    paragraphs = paragraphs(text)
    paragraph = if asks?(text), do: List.last(paragraphs), else: List.first(paragraphs)
    cut(paragraph)
  end

  def note("failed", reason) when is_binary(reason), do: cut(reason)
  def note(_status, _text), do: nil

  # The text's paragraphs that have words in them, in order, leaving out
  # fenced code blocks (an unclosed fence runs to the end).
  defp paragraphs(text) do
    {paragraphs, lines, _fenced?} =
      text
      |> String.split(~r/\r?\n/)
      |> Enum.reduce({[], [], false}, &paragraph_line/2)

    paragraphs
    |> close(lines)
    |> Enum.reverse()
    |> Enum.filter(&Regex.match?(~r/[[:alnum:]]/u, &1))
  end

  defp paragraph_line(line, {paragraphs, lines, fenced?}) do
    cond do
      fence?(line) -> {close(paragraphs, lines), [], not fenced?}
      fenced? -> {paragraphs, lines, fenced?}
      String.trim(line) == "" -> {close(paragraphs, lines), [], fenced?}
      true -> {paragraphs, [line | lines], fenced?}
    end
  end

  defp fence?(line) do
    trimmed = String.trim_leading(line)
    String.starts_with?(trimmed, "```") or String.starts_with?(trimmed, "~~~")
  end

  defp close(paragraphs, []), do: paragraphs
  defp close(paragraphs, lines), do: [lines |> Enum.reverse() |> Enum.join("\n") | paragraphs]

  defp cut(nil), do: nil

  defp cut(text) do
    case text |> String.split() |> Enum.join(" ") do
      "" ->
        nil

      line ->
        if String.length(line) <= @note_limit,
          do: line,
          else: Text.cut_at_word(line, @note_limit - 3) <> "..."
    end
  end
end
