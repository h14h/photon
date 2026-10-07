defmodule Photon.Threads.State do
  @moduledoc """
  A thread's state, worked out by code from facts the hub stores (section
  2.2 of `docs/plans/step-4-blip-as-coordinator.md`): never by a model,
  and never stored itself (rule 15).

  `of/3` takes the facts (whether a run is in progress, the thread's open
  `ask_blip` question, how its last run ended, when the owner last looked
  or resolved it) and the time, and gives the first state whose rule
  holds:

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
  done, however old. `label/2` gives the words the pages and Blip's tools
  show for a state, so they read the same everywhere.

  When a run ends, `asks?/1` says whether its answer ended with a
  question to the user, and `note/2` makes the short note stored with it.
  Both are total: they take any term and return a value, since they run
  inside the harness's settle hook (section 3.1).
  """

  # Functional core: no processes, no I/O. The time comes in as an argument.
  use Boundary, type: :strict, deps: []

  @typedoc "A thread's state."
  @type t :: :waiting | :asking | :running | :failed | :unread | :quiet | :idle

  @typedoc """
  What a state is worked out from: `busy?` (a run is in progress),
  `question` (`:with_owner` when any open `ask_blip` question is with the
  owner, else `:with_blip` when one is asked, else nil), the last run's
  facts as stored on the thread, `active_at` (the thread's last message),
  `seen_at` and `resolved_at`.
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

  # The longest note stored with a run's end.
  @note_limit 280

  @doc "The thread's state at `now`, by the first rule of the moduledoc's list that holds."
  @spec of(facts(), DateTime.t(), opts()) :: t()
  def of(facts, now, opts), do: live(facts) || settled(facts, now, opts)

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
  had its page open since: never, or only before the run ended. A thread
  row or a facts map both work.
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

  # The later of the thread's last message and its last run's end.
  defp last_activity(%{active_at: active_at, last_run_ended_at: ended_at}) do
    [active_at, ended_at]
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> Enum.max(DateTime, fn -> nil end)
  end

  @doc """
  The words for a state, as every page and Blip's tools show it. An idle
  thread reads "Resolved" when the owner resolved it, "Done" when its
  last run finished, and "Idle" otherwise.
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
  The note stored with a run's end, from how it ended and its text: for
  `"done"`, the answer's first paragraph, or its last when it asks
  (`asks?/1`); for `"failed"`, the reason. Whitespace is collapsed and
  the note cut to #{@note_limit} characters at a word boundary, with
  "..." when cut. Nil for a stopped run, and for no text.
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
          else: cut_at_word(line, @note_limit - 3) <> "..."
    end
  end

  # At most `limit` characters, ending at a word boundary when there is
  # one, without trailing punctuation before the "...".
  defp cut_at_word(text, limit) do
    head = String.slice(text, 0, limit + 1)

    cut =
      case Regex.run(~r/^(.*\S)\s/u, head) do
        [_, cut] -> String.slice(cut, 0, limit)
        nil -> String.slice(text, 0, limit)
      end

    String.replace(cut, ~r/[\s.,;:]+$/u, "")
  end
end
