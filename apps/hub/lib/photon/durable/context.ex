defmodule Photon.Durable.Context do
  @moduledoc """
  Turns a transcript into model input. The model sees entries from the newest
  reset onward. Every tool call gets exactly one result: a call whose result
  never landed (the run was stopped, or the hub died) gets an "interrupted"
  one, so the provider always sees a well-formed conversation.

  Tool results from earlier runs are shortened, so a long conversation of
  command output and screenshots stays within the model's context and the
  request size limit:

    * an image part becomes a short text saying it is no longer shown; the
      result's other text, such as the image's dimensions, stays
    * a text part over 4,000 code points keeps its first and last
      2,000 around a marker saying how much was left out, with the
      result's `details["full_output"]` when the tool set one (where the
      complete output is kept)

  The cut is at the current run's first `"user"` entry: the first one after
  the newest entry that ended a run, an answer with no tool calls or an
  error that isn't a notice. A steer placed partway through a run (after a
  tool round) comes later, so it doesn't move the cut: the run's results
  stay whole, and the model sees what it just asked for. The cut moves only
  when a new run starts, so the requests within a run share a stable
  prefix for prompt caching. The rule applies to every tool's results and
  takes nothing from the profile.

  An earlier run can also ask to shrink further. When its first user
  entry's source has an `"older"` map (`%{"text" => stub,
  "drop_if_answer" => answer}`, both optional but the stub), the run is
  sent smaller once a later run has started:

    * when no other user entry joined it (no steer) and its final answer,
      trimmed, lowercased and without a trailing `.`, equals
      `"drop_if_answer"` treated the same way, the whole run is left out:
      the user entry, its tool calls and results, and the answer
    * otherwise the user entry is sent as the stub, and the run's text
      results are cut to 500 code points instead of 4,000, with the same
      head-and-tail cut and marker

  Blip's digests and reviews use it (section 5.3 of
  `docs/plans/step-5-ambient-mode.md`), so a day of them doesn't fill
  every later request; nothing here knows what a digest is. The current
  run is never touched, and an entry without `"older"` is sent as above.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [Photon.Durable.Entry, PhotonCore]

  alias Photon.Durable.Entry
  alias PhotonCore.{Message, Output}

  # Code points an older text part keeps: half from its start, half from its end.
  @older_text_limit 4_000
  # The same, in a run whose user entry asked to shrink (`"older"`).
  @stub_text_limit 500
  @image_gone "(image no longer shown; call view_image again to see it)"

  @spec messages([Entry.t()]) :: [Message.t()]
  def messages(entries) do
    case entries |> since_reset() |> runs() |> Enum.reverse() do
      [] ->
        []

      [current | earlier] ->
        earlier
        |> Enum.reverse()
        |> Enum.flat_map(&older/1)
        |> Enum.concat(current)
        |> Enum.flat_map(&message/1)
        |> pair_tool_results()
    end
  end

  defp since_reset(entries) do
    case last_index(entries, "reset") do
      nil -> entries
      index -> Enum.drop(entries, index)
    end
  end

  # The entries in runs, oldest first; the last is the current run. A user
  # entry starts a run when it is the first one, or the first after an
  # entry that ended a run; later ones are steers placed mid-run and stay
  # in theirs. Entries before the first user entry (a reset) are a run of
  # their own, so with no user entry at all everything is the current run.
  defp runs(entries) do
    {runs, run, _open} =
      Enum.reduce(entries, {[], [], true}, fn
        %Entry{kind: "user"} = entry, {runs, run, true} -> {push(runs, run), [entry], false}
        entry, {runs, run, open} -> {runs, [entry | run], open or run_end?(entry)}
      end)

    runs |> push(run) |> Enum.reverse()
  end

  defp push(runs, []), do: runs
  defp push(runs, run), do: [Enum.reverse(run) | runs]

  defp run_end?(%Entry{kind: "assistant", data: %{"message" => message}}),
    do: Message.tool_calls(message) == []

  defp run_end?(%Entry{kind: "error", data: data}), do: data["notice"] != true
  defp run_end?(_entry), do: false

  defp last_index(entries, kind) do
    entries
    |> Enum.with_index()
    |> Enum.filter(fn {e, _} -> e.kind == kind end)
    |> List.last()
    |> case do
      nil -> nil
      {_, index} -> index
    end
  end

  # An earlier run, as the model sees it: left out, as its stub, or with
  # its tool results shortened.
  defp older([%Entry{kind: "user", data: %{"source" => source}} = first | rest] = run) do
    case source do
      %{"older" => %{"text" => text} = asked} when is_binary(text) ->
        if dropped?(rest, asked["drop_if_answer"]),
          do: [],
          else: [
            put_in(first.data["message"], Message.user(text))
            | shorten_all(rest, @stub_text_limit)
          ]

      _no_stub ->
        shorten_all(run, @older_text_limit)
    end
  end

  defp older(run), do: shorten_all(run, @older_text_limit)

  defp shorten_all(entries, limit), do: Enum.map(entries, &shorten(&1, limit))

  # A run (after its user entry) is left out when nobody steered it and it
  # answered what its user entry said it would answer when there was
  # nothing to say.
  defp dropped?(rest, drop_if) when is_binary(drop_if) do
    not Enum.any?(rest, &(&1.kind == "user")) and
      case Enum.find(rest, &run_end?/1) do
        %Entry{kind: "assistant", data: %{"message" => answer}} ->
          plain(Message.text_of(answer)) == plain(drop_if)

        _no_answer ->
          false
      end
  end

  defp dropped?(_rest, _drop_if), do: false

  defp plain(text),
    do: text |> String.trim() |> String.downcase() |> String.replace_suffix(".", "")

  defp shorten(
         %Entry{kind: "tool_result", data: %{"message" => %{"content" => parts}}} = entry,
         limit
       )
       when is_list(parts) do
    hint = full_output(entry.data["details"])
    shortened = Enum.map(parts, &shorten_part(&1, hint, limit))
    %{entry | data: put_in(entry.data, ["message", "content"], shortened)}
  end

  defp shorten(entry, _limit), do: entry

  defp full_output(%{"full_output" => hint}) when is_binary(hint) and hint != "", do: hint
  defp full_output(_details), do: nil

  defp shorten_part(%{"type" => "image"}, _hint, _limit), do: Message.text(@image_gone)

  # A text no longer in bytes than the limit can't be over it in code points.
  defp shorten_part(%{"type" => "text", "text" => text} = part, hint, limit)
       when is_binary(text) and byte_size(text) > limit do
    codepoints = text |> Output.sanitize() |> String.to_charlist()
    count = length(codepoints)

    if count > limit,
      do: %{part | "text" => cut(codepoints, count, hint, limit)},
      else: part
  end

  defp shorten_part(part, _hint, _limit), do: part

  defp cut(codepoints, count, hint, limit) do
    half = div(limit, 2)
    {head, rest} = Enum.split(codepoints, half)
    tail = Enum.drop(rest, length(rest) - half)
    List.to_string(head) <> marker(count - limit, hint) <> List.to_string(tail)
  end

  defp marker(left_out, nil),
    do: "\n\n...#{left_out} characters of this older result left out...\n\n"

  defp marker(left_out, hint) do
    "\n\n...#{left_out} characters of this older result left out. " <>
      String.trim_trailing(hint, ".") <> "...\n\n"
  end

  defp message(%Entry{kind: kind, data: %{"message" => message}})
       when kind in ~w(user assistant tool_result),
       do: [message]

  defp message(%Entry{kind: "reset", data: %{"handoff" => handoff}})
       when handoff not in [nil, ""] do
    [Message.user("[The conversation was reset. Notes carried over:]\n\n" <> handoff)]
  end

  defp message(_entry), do: []

  defp pair_tool_results(messages), do: pair(messages, [])

  defp pair([], acc), do: Enum.reverse(acc)

  defp pair([%{"role" => "assistant"} = assistant | rest], acc),
    do: pair_calls(Message.tool_calls(assistant), assistant, rest, acc)

  # A result without its call can't be sent.
  defp pair([%{"role" => "tool"} | rest], acc), do: pair(rest, acc)
  defp pair([message | rest], acc), do: pair(rest, [message | acc])

  # Each call's result goes right after the assistant message that made it.
  defp pair_calls([], assistant, rest, acc), do: pair(rest, [assistant | acc])

  defp pair_calls(calls, assistant, rest, acc) do
    {results, rest} = Enum.split_while(rest, &(&1["role"] == "tool"))
    by_id = Map.new(results, &{&1["tool_call_id"], &1})
    paired = Enum.map(calls, &result_for(&1, by_id))
    pair(rest, Enum.reverse(paired, [assistant | acc]))
  end

  defp result_for(call, by_id) do
    Map.get_lazy(by_id, call["id"], fn ->
      Message.tool_result(call["id"], "No result: this call was interrupted before it finished.")
    end)
  end
end
