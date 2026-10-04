defmodule Photon.Durable.Context do
  @moduledoc """
  Turns a transcript into model input. The model sees entries from the newest
  reset onward. Every tool call gets exactly one result: a call whose result
  never landed (the run was stopped, or the hub died) gets an "interrupted"
  one, so the provider always sees a well-formed conversation.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [Photon.Durable.Entry, PhotonCore]

  alias Photon.Durable.Entry
  alias PhotonCore.Message

  @spec messages([Entry.t()]) :: [Message.t()]
  def messages(entries) do
    entries
    |> since_reset()
    |> Enum.flat_map(&message/1)
    |> pair_tool_results()
  end

  defp since_reset(entries) do
    case entries
         |> Enum.with_index()
         |> Enum.filter(fn {e, _} -> e.kind == "reset" end)
         |> List.last() do
      nil -> entries
      {_, index} -> Enum.drop(entries, index)
    end
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
