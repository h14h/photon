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
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [Photon.Durable.Entry, PhotonCore]

  alias Photon.Durable.Entry
  alias PhotonCore.{Message, Output}

  # Code points an older text part keeps: half from its start, half from its end.
  @older_text_limit 4_000
  @image_gone "(image no longer shown; call view_image again to see it)"

  @spec messages([Entry.t()]) :: [Message.t()]
  def messages(entries) do
    {earlier, current} = entries |> since_reset() |> split_at_run()

    earlier
    |> Enum.map(&shorten/1)
    |> Enum.concat(current)
    |> Enum.flat_map(&message/1)
    |> pair_tool_results()
  end

  defp since_reset(entries) do
    case last_index(entries, "reset") do
      nil -> entries
      index -> Enum.drop(entries, index)
    end
  end

  # Entries before the current run's first user entry belong to earlier
  # runs. A user entry starts a run when it is the first one, or the first
  # after an entry that ended a run; later ones are steers placed mid-run.
  defp split_at_run(entries) do
    {start, _open} =
      entries
      |> Enum.with_index()
      |> Enum.reduce({nil, true}, fn
        {%Entry{kind: "user"}, index}, {_start, true} -> {index, false}
        {entry, _index}, {start, open} -> {start, open or run_end?(entry)}
      end)

    case start do
      nil -> {[], entries}
      index -> Enum.split(entries, index)
    end
  end

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

  defp shorten(%Entry{kind: "tool_result", data: %{"message" => %{"content" => parts}}} = entry)
       when is_list(parts) do
    hint = full_output(entry.data["details"])
    shortened = Enum.map(parts, &shorten_part(&1, hint))
    %{entry | data: put_in(entry.data, ["message", "content"], shortened)}
  end

  defp shorten(entry), do: entry

  defp full_output(%{"full_output" => hint}) when is_binary(hint) and hint != "", do: hint
  defp full_output(_details), do: nil

  defp shorten_part(%{"type" => "image"}, _hint), do: Message.text(@image_gone)

  # A text no longer in bytes than the limit can't be over it in code points.
  defp shorten_part(%{"type" => "text", "text" => text} = part, hint)
       when is_binary(text) and byte_size(text) > @older_text_limit do
    codepoints = text |> Output.sanitize() |> String.to_charlist()
    count = length(codepoints)

    if count > @older_text_limit,
      do: %{part | "text" => cut(codepoints, count, hint)},
      else: part
  end

  defp shorten_part(part, _hint), do: part

  defp cut(codepoints, count, hint) do
    half = div(@older_text_limit, 2)
    {head, rest} = Enum.split(codepoints, half)
    tail = Enum.drop(rest, length(rest) - half)
    List.to_string(head) <> marker(count - @older_text_limit, hint) <> List.to_string(tail)
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
