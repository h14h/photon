defmodule Photon.Assistant.MockAmbient do
  @moduledoc """
  The scripted Blip's replies to ambient mode's messages (section 8.1 of
  `docs/plans/step-5-ambient-mode.md`): a digest (`[Digest]`) and a daily
  review (`[Daily review]`), as `Photon.Ambient.Text` writes them.
  `Photon.Assistant.MockCoordinator.unasked/2` tries `unasked/2` first.

  Memory lines `- ignore: <word>` (in the request's system text, under
  `## Memory`, as the question script reads memory) name words to leave
  out: a line that contains one, ignoring case, isn't told.

    * A digest: each line under "New to the user:" left after the filter
      becomes a reply line, `Fix the pump in Garden finished: Replaced the
      fuse.` or `The schedule "check the gutters" in Garden stopped after
      an error.` Lines under "Already seen" are left out.
    * A review: the lines left after the filter become `These have sat
      for a while:`, one line each (`- Fix the pump in Garden (c_123),
      stopped 4 days ago.`), and how to pick one up or close it. The
      scripted reply shows IDs so a demo can name them; the real prompt
      tells Blip not to.

  With no line left, the reply is `[nothing to tell]`, which makes no
  bubble and no activity row. It never calls a tool.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [PhotonCore]

  alias PhotonCore.Message

  @nothing_to_tell "[nothing to tell]"

  @pick_up ~s{Say "tell <id>: ..." to pick one up, or press Resolve on it on Home to close it.}

  @help """
  - in ambient mode I tell you what's new in a digest and list the threads a daily review names, leaving out lines with a word from a `- ignore: <word>` memory line, like `remember ignore: pump`
  """

  @doc "The help text's lines for these replies, one Markdown list item each."
  @spec help() :: String.t()
  def help, do: @help

  @doc """
  The scripted reply to a message whose text parts (`texts`) are all
  digests or reviews, with the memory read from `request`'s system text;
  nil for any other message.
  """
  @spec unasked([String.t()], map()) :: Message.t() | nil
  def unasked(texts, request) do
    if texts != [] and Enum.all?(texts, &ambient?/1) do
      ignored = ignored(system(request))

      texts
      |> Enum.flat_map(&reply_lines(&1, ignored))
      |> reply()
    end
  end

  defp ambient?("[Digest]" <> _rest), do: true
  defp ambient?("[Daily review]" <> _rest), do: true
  defp ambient?(_text), do: false

  defp system(request) when is_map(request) do
    case Map.get(request, :system) do
      system when is_binary(system) -> system
      _none -> ""
    end
  end

  defp reply([]), do: Message.assistant(@nothing_to_tell)
  defp reply(lines), do: lines |> Enum.join("\n") |> Message.assistant()

  defp reply_lines("[Digest]" <> _rest = text, ignored) do
    text
    |> block("New to the user:")
    |> kept(ignored)
    |> Enum.map(&digest_line/1)
  end

  defp reply_lines("[Daily review]" <> _rest = text, ignored) do
    case text |> String.split("\n", parts: 2) |> tl() |> rows() |> kept(ignored) do
      [] ->
        []

      rows ->
        List.flatten([
          "These have sat for a while:",
          Enum.map(rows, &review_line/1),
          @pick_up
        ])
    end
  end

  # The `- ` rows right under the line `heading`.
  defp block(text, heading) do
    case String.split(text, "\n" <> heading <> "\n", parts: 2) do
      [_before, rest] -> rows([rest])
      _no_block -> []
    end
  end

  # The `- ` rows at the start of the text, up to the first other line.
  defp rows([rest]) do
    rest
    |> String.split("\n")
    |> Enum.take_while(&String.starts_with?(&1, "- "))
  end

  defp rows([]), do: []

  defp kept(rows, ignored) do
    Enum.reject(rows, fn row ->
      row = String.downcase(row)
      Enum.any?(ignored, &String.contains?(row, &1))
    end)
  end

  ## The digest's lines

  defp digest_line(row) do
    cond do
      match = finished(row) -> match
      match = schedule(row) -> match
      true -> String.replace_prefix(row, "- ", "")
    end
  end

  # `- Garden / "Fix the pump" (c_123) finished. It said: Replaced the fuse.`
  defp finished(row) do
    case Regex.run(~r/\A- (.*?) \/ "(.*)" \([^()]*\) finished\.(?: It said: (.*))?\z/s, row,
           capture: :all_but_first
         ) do
      [project, title, note] -> "#{title} in #{project} finished: #{note}"
      [project, title] -> "#{title} in #{project} finished."
      nil -> nil
    end
  end

  # `- Garden / schedule sc_9 "check the gutters" stopped after an error: ...`
  # or `- Your schedule sc_9 "..." stopped after an error.`
  defp schedule(row) do
    cond do
      captures = Regex.run(~r/\A- Your schedule \S+ (".*") stopped after an error\b/, row) ->
        [_row, prompt] = captures
        "Your schedule #{prompt} stopped after an error."

      captures =
          Regex.run(~r/\A- (.*?) \/ schedule \S+ (".*") stopped after an error\b/, row) ->
        [_row, project, prompt] = captures
        "The schedule #{prompt} in #{project} stopped after an error."

      true ->
        nil
    end
  end

  ## The review's lines

  # `- Garden / "Fix the pump" (c_123): stopped 4 days ago. It last said: ...`
  defp review_line(row) do
    case Regex.run(
           ~r/\A- (.*?) \/ "(.*?)" \((c_[^()\s]*)\): ((?:stopped|last touched|failed) \d+ [a-z]+ ago|waiting on the user for \d+ [a-z]+)/,
           row,
           capture: :all_but_first
         ) do
      [project, title, id, state] ->
        "- #{title} in #{project} (#{id}), #{String.replace(state, "the user", "you")}."

      nil ->
        row
    end
  end

  ## Memory

  # The words of the memory's `- ignore: <word>` lines, in lower case.
  defp ignored(system) do
    case String.split(system, "## Memory\n", parts: 2) do
      [_before, rest] -> rest |> String.split("\n## ", parts: 2) |> hd() |> ignore_lines()
      _no_memory -> []
    end
  end

  defp ignore_lines(shown) do
    for line <- String.split(shown, "\n"),
        [word] <- [
          Regex.run(~r/\A-\s*ignore\s*:\s*(.+)\z/i, String.trim(line), capture: :all_but_first)
        ],
        word = word |> String.trim() |> String.downcase(),
        word != "",
        do: word
  end
end
