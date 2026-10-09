defmodule Photon.Ambient.Text do
  @moduledoc """
  The words of ambient mode's messages to Blip.

  A digest (`digest/2`) or a daily review (`review/3`) is one text part
  of a message in Blip's conversation, which the model reads. It names
  each project by name and each thread by title and ID, as they are when
  the message is written. Each also has:

    * a ref (`digest_ref/2`, `review_ref/2`) for the message's
      `source["signals"]`, from which the pages draw it with the threads'
      current titles
    * an older stub (`digest_older/2`, `review_older/2`) for the
      message's `source["older"]`: the one line Blip's later requests see
      in its place, and the answer that leaves the run out of them
      altogether (`"[nothing to tell]"`)

  They take what `Photon.Ambient.Rules.digest/3` and `review/3` give, and
  the time, all passed in. Every text is bounded: notes are cut to 280
  characters in a digest, a review's lines to 400, a digest to 6,000
  characters and a stub to 300. Times are UTC, since the hub
  doesn't know the owner's time zone.
  """

  # Functional core: no processes, no I/O. The time comes in as an argument.
  use Boundary, type: :strict, deps: []

  @note_limit 280
  @prompt_limit 120
  @line_limit 400
  @digest_limit 6_000
  @older_limit 300
  @older_subjects 5
  @subject_limit 60

  @nothing_to_tell "[nothing to tell]"

  @typedoc "What `Photon.Ambient.Rules.digest/3` gives."
  @type digest :: map()

  @typedoc "What `Photon.Ambient.Rules.review/3` gives."
  @type review :: map()

  @typedoc "An older stub for a message's source: the line, and the answer that drops the run."
  @type older :: %{required(String.t()) => String.t()}

  ## The digest

  @doc """
  The digest's text. Its window starts at the doc's `"last_sent_at"` (the
  last digest posted; a skipped firing doesn't move it), or, before the
  first, at `"on_since"`, when ambient mode was turned on. The "Already
  seen" block is left out when it is empty, and zero counts are left out
  of the closing line. Rows that don't fit in #{@digest_limit} characters
  are counted with the rest.
  """
  @spec digest(digest(), map()) :: String.t()
  def digest(digest, doc) do
    header = "[Digest] " <> window(doc) <> ", in your user's projects."
    now_line = now_line(Map.get(digest, :snapshot, %{}))

    # Room for the header, the block headings, the "more" lines and the
    # closing line; what is left goes to the rows, new ones first.
    reserved = String.length(header) + String.length(now_line) + 200
    {new_lines, more_new, budget} = block(digest, :new, :more_new, @digest_limit - reserved)
    {smaller_lines, more_smaller, _budget} = block(digest, :smaller, :more_smaller, budget)

    # The header is never blank, so the text needs no blank check.
    [
      header,
      new_heading(new_lines, more_new),
      new_lines,
      more_new_line(more_new),
      seen_block(smaller_lines, more_smaller),
      now_line
    ]
    |> lines()
    |> clip(@digest_limit)
  end

  # The text's lines, nested lists flattened and nils left out, trimmed.
  defp lines(parts),
    do: parts |> List.flatten() |> Enum.reject(&is_nil/1) |> Enum.join("\n") |> String.trim()

  # A block's lines that fit in `budget`, how many more there are (those
  # the digest cut and those that didn't fit), and what is left of it.
  defp block(digest, rows_key, more_key, budget) do
    line = if rows_key == :new, do: &new_line/1, else: &smaller_line/1
    lines = digest |> Map.get(rows_key, []) |> Enum.map(line)
    {kept, left, dropped} = fit(lines, budget)
    {kept, Map.get(digest, more_key, 0) + dropped, left}
  end

  defp new_heading([], 0), do: "New to the user: nothing."
  defp new_heading(_lines, _more), do: "New to the user:"

  defp window(doc) do
    doc = if is_map(doc), do: doc, else: %{}

    case {time(Map.get(doc, "last_sent_at")), time(Map.get(doc, "on_since"))} do
      {%DateTime{} = sent, _on} -> "Since the last digest (#{stamp(sent)})"
      {nil, %DateTime{} = on} -> "Since ambient mode was turned on (#{stamp(on)})"
      {nil, nil} -> "Since ambient mode was turned on"
    end
  end

  defp new_line(%{kind: "finished"} = row) do
    words =
      case one_line(row.note, @note_limit) do
        nil -> "- #{where(row)} finished."
        note -> "- #{where(row)} finished. It said: #{note}"
      end

    cut(words, @line_limit)
  end

  defp new_line(%{kind: "schedule_stopped"} = row) do
    words =
      case one_line(row.reason, @note_limit) do
        nil -> "- #{schedule(row)} stopped after an error."
        reason -> "- #{schedule(row)} stopped after an error: #{reason}"
      end

    cut(words, @line_limit)
  end

  defp new_line(row), do: smaller_line(row)

  defp smaller_line(row), do: row |> smaller_words() |> cut(@line_limit)

  defp smaller_words(%{kind: "finished"} = row),
    do: "- #{where(row)} finished; the user has seen it."

  defp smaller_words(%{kind: "file_written"} = row) do
    verb = if row.deleted?, do: "deleted", else: "written"
    "- #{project(row)} / context file #{row.name} #{verb} by #{writer(row)}."
  end

  defp smaller_words(%{kind: "project_created"} = row),
    do: "- The user started project #{project(row)}."

  defp smaller_words(%{kind: "purpose_changed"} = row),
    do: "- The user edited project #{project(row)}'s name or Purpose."

  defp smaller_words(%{kind: "thread_started"} = row),
    do: "- The user started #{thread(row)} in #{project(row)}."

  defp smaller_words(%{kind: "resolved"} = row),
    do: "- The user resolved #{where(row)}."

  defp smaller_words(%{kind: "schedule_stopped"} = row),
    do: "- #{schedule(row)} stopped after an error."

  defp smaller_words(row), do: "- #{where(row)} changed."

  defp writer(%{writer: "user"}), do: "the user"

  defp writer(%{writer: writer, writer_title: title}) when is_binary(title),
    do: ~s{"#{title}" (#{writer})}

  defp writer(%{writer: writer}) when is_binary(writer), do: "thread #{writer}"
  defp writer(_row), do: "someone"

  defp more_new_line(0), do: nil
  defp more_new_line(n), do: "...and #{n} more; list_threads with state unread shows them."

  defp seen_block([], 0), do: nil

  defp seen_block(lines, more) do
    more_line = if more > 0, do: "...and #{more} more smaller #{plural(more, "change")}."
    ["Already seen by the user, or done by them:", lines, more_line]
  end

  defp now_line(snapshot) do
    parts =
      [
        {Map.get(snapshot, :running, 0), "running"},
        {Map.get(snapshot, :waiting, 0), "waiting on the user"},
        {Map.get(snapshot, :failed, 0), "failed"}
      ]
      |> Enum.reject(fn {n, _words} -> n == 0 end)
      |> Enum.map(fn {n, words} -> "#{n} #{words}" end)

    case parts do
      [] -> "Now: nothing running or waiting."
      parts -> "Now: " <> Enum.join(parts, ", ") <> "."
    end
  end

  # The lines that fit in `budget` characters (each with its newline),
  # what is left of it, and how many didn't fit.
  defp fit(lines, budget) do
    {kept, left, dropped} =
      Enum.reduce(lines, {[], budget, 0}, fn line, {kept, left, dropped} ->
        size = String.length(line) + 1

        if dropped == 0 and size <= left,
          do: {[line | kept], left - size, dropped},
          else: {kept, left, dropped + 1}
      end)

    {Enum.reverse(kept), left, dropped}
  end

  @doc """
  The digest's ref for the message's `source["signals"]`: its key, one
  item per row (the new rows with their notes and reasons), and how many
  more of each.
  """
  @spec digest_ref(digest(), String.t()) :: map()
  def digest_ref(digest, key) do
    %{
      "kind" => "digest",
      "key" => key,
      "items" =>
        Enum.map(Map.get(digest, :new, []), &ref_item/1) ++
          Enum.map(Map.get(digest, :smaller, []), &ref_item/1),
      "more" => Map.get(digest, :more_new, 0),
      "more_smaller" => Map.get(digest, :more_smaller, 0)
    }
  end

  defp ref_item(row) do
    fields =
      case row.kind do
        "finished" -> [:thread_id, :title, :note]
        "schedule_stopped" -> [:schedule_id, :prompt, :reason]
        "file_written" -> [:name, :writer, :writer_title]
        kind when kind in ["thread_started", "resolved"] -> [:thread_id, :title]
        _project -> []
      end

    # A smaller row's note isn't shown, so the ref doesn't carry it.
    fields = if row.new?, do: fields, else: fields -- [:note]

    [:project_id, :slug, :project | fields]
    |> Enum.map(&{Atom.to_string(&1), Map.get(row, &1)})
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> Map.merge(%{"kind" => row.kind, "new" => row.new?})
    |> then(&if(row.kind == "file_written", do: Map.put(&1, "deleted", row.deleted?), else: &1))
  end

  @doc """
  The stub Blip's later requests see in place of a digest delivered at
  `now`: its counts and up to #{@older_subjects} of its new subjects, at
  most #{@older_limit} characters.
  """
  @spec digest_older(digest(), DateTime.t()) :: older()
  def digest_older(digest, now) do
    new_count = length(Map.get(digest, :new, [])) + Map.get(digest, :more_new, 0)
    smaller_count = length(Map.get(digest, :smaller, [])) + Map.get(digest, :more_smaller, 0)

    counts =
      if smaller_count > 0,
        do: "#{new_count} new, #{smaller_count} smaller",
        else: "#{new_count} new"

    base = "[Digest delivered #{stamp(now)}: #{counts}."
    subjects = Enum.map(Map.get(digest, :new, []), &subject/1)

    older(&"#{base} New: #{&1}.]", base <> "]", subjects, new_count)
  end

  defp subject(%{kind: "schedule_stopped"} = row) do
    prompt = ~s{schedule "#{one_line(row.prompt, @subject_limit) || ""}"}

    case row.project do
      nil -> "your " <> prompt
      _project -> "#{project(row)} / #{prompt}"
    end
  end

  defp subject(row), do: "#{project(row)} / \"#{one_line(row.title, @subject_limit) || ""}\""

  ## The review

  @doc """
  The daily review's text: a header saying how many threads have sat
  untouched and for how long (`quiet_after`), one line per thread shown
  (cut to #{@line_limit} characters), and how many more. `answers` has
  each thread's latest answer by ID, which a stopped thread's line
  quotes.
  """
  @spec review(review(), %{optional(String.t()) => String.t() | nil}, DateTime.t()) ::
          String.t()
  def review(review, answers, now) do
    rows = Map.get(review, :rows, [])
    more = Map.get(review, :more, 0)
    total = length(rows) + more

    header =
      "[Daily review] #{total} #{plural(total, "thread")} #{if total == 1, do: "has", else: "have"} " <>
        "sat untouched#{for_at_least(Map.get(review, :quiet_after, 0))}:"

    lines = Enum.map(rows, &review_line(&1, Map.get(answers, &1.thread_id), now))
    more_line = if more > 0, do: "...and #{more} more; list_threads with state quiet shows them."

    [header | lines]
    |> Enum.concat(List.wrap(more_line))
    |> Enum.join("\n")
  end

  defp for_at_least(seconds) when is_integer(seconds) and seconds >= 3600,
    do: " for #{duration(seconds)} or more"

  defp for_at_least(_seconds), do: ""

  defp review_line(row, answer, now) do
    ago = ago(row.since, now)

    words =
      case row.state do
        :failed -> with_detail("failed #{ago} ago", ":", row.detail)
        :waiting -> with_detail("waiting on the user for #{ago}", ":", row.detail)
        :quiet -> with_detail("#{quiet_words(row)} #{ago} ago", ". It last said:", answer)
      end

    cut("- #{where(row)}: #{words}", @line_limit)
  end

  defp quiet_words(%{last_run_status: "stopped"}), do: "stopped"
  defp quiet_words(_row), do: "last touched"

  defp with_detail(words, joiner, detail) do
    case one_line(detail, @line_limit) do
      nil -> words <> "."
      detail -> "#{words}#{joiner} #{detail}"
    end
  end

  @doc """
  The review's ref for the message's `source["signals"]`: its key, one
  item per thread shown with its state and last touch (ISO 8601), and how
  many more.
  """
  @spec review_ref(review(), String.t()) :: map()
  def review_ref(review, key) do
    items =
      for row <- Map.get(review, :rows, []) do
        %{
          "thread_id" => row.thread_id,
          "title" => row.title,
          "project_id" => row.project_id,
          "slug" => row.slug,
          "project" => row.project,
          "state" => Atom.to_string(row.state),
          "since" => DateTime.to_iso8601(row.since)
        }
      end

    %{"kind" => "review", "key" => key, "items" => items, "more" => Map.get(review, :more, 0)}
  end

  @doc """
  The stub Blip's later requests see in place of a review delivered at
  `now`: up to #{@older_subjects} of its threads, at most #{@older_limit}
  characters.
  """
  @spec review_older(review(), DateTime.t()) :: older()
  def review_older(review, now) do
    rows = Map.get(review, :rows, [])
    total = length(rows) + Map.get(review, :more, 0)
    base = "[Daily review delivered #{stamp(now)}:"

    older(
      &"#{base} #{&1}.]",
      "#{base} #{total} #{plural(total, "thread")}.]",
      Enum.map(rows, &subject/1),
      total
    )
  end

  # The stub's text: `with_subjects` given as many subjects (and how many
  # more) as fit in 300 characters, or `bare` when none does.
  defp older(with_subjects, bare, subjects, total) do
    shown = Enum.take(subjects, @older_subjects)

    text =
      Enum.find_value(length(shown)..1//-1, fn n ->
        rest = total - n
        more = if rest > 0, do: ", and #{rest} more", else: ""
        text = with_subjects.(Enum.join(Enum.take(shown, n), ", ") <> more)
        if String.length(text) <= @older_limit, do: text
      end)

    %{"text" => text || cut(bare, @older_limit), "drop_if_answer" => @nothing_to_tell}
  end

  ## Shared

  @doc """
  How long ago `since` was at `now`, in words: whole days ("4 days"),
  whole hours under a day ("5 hours"), whole minutes under an hour.
  """
  @spec ago(DateTime.t(), DateTime.t()) :: String.t()
  def ago(since, now), do: duration(max(DateTime.diff(now, since, :second), 0))

  defp duration(seconds) when seconds >= 86_400, do: count(div(seconds, 86_400), "day")
  defp duration(seconds) when seconds >= 3_600, do: count(div(seconds, 3_600), "hour")
  defp duration(seconds), do: count(max(div(seconds, 60), 1), "minute")

  defp count(n, unit), do: "#{n} #{plural(n, unit)}"

  defp plural(1, word), do: word
  defp plural(_n, word), do: word <> "s"

  # `Garden / "Fix the pump" (c_123)`.
  defp where(row), do: "#{project(row)} / #{thread(row)}"

  defp thread(row), do: ~s{"#{row.title || ""}" (#{row.thread_id})}

  defp project(row), do: row.project || "?"

  defp schedule(%{project: nil} = row),
    do: ~s{Your schedule #{row.schedule_id} "#{one_line(row.prompt, @prompt_limit) || ""}"}

  defp schedule(row),
    do:
      ~s{#{project(row)} / schedule #{row.schedule_id} "#{one_line(row.prompt, @prompt_limit) || ""}"}

  defp time(%DateTime{} = at), do: at

  defp time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      _error -> nil
    end
  end

  defp time(_none), do: nil

  # "2026-10-07 12:00 UTC".
  defp stamp(at), do: Calendar.strftime(DateTime.shift_zone!(at, "Etc/UTC"), "%Y-%m-%d %H:%M UTC")

  # On one line, cut to `limit` characters; nil when there is no text.
  defp one_line(text, limit) when is_binary(text),
    do: text |> String.split() |> Enum.join(" ") |> cut(limit)

  defp one_line(_text, _limit), do: nil

  # At most `limit` characters, ending in "..." when cut; nil when empty.
  defp cut(text, limit) do
    case String.trim(text) do
      "" ->
        nil

      text ->
        clip(text, limit)
    end
  end

  # `text` cut to `limit` characters, ending "..." when it was longer.
  defp clip(text, limit) do
    if String.length(text) <= limit,
      do: text,
      else: String.trim_trailing(String.slice(text, 0, limit - 3)) <> "..."
  end
end
