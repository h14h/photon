defmodule PhotonCore.Generators do
  @moduledoc """
  StreamData generators shared by the property tests.
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  use ExUnitProperties

  alias PhotonCore.Message

  @doc "Byte offsets to cut a stream at (see `PhotonCore.Fixtures.split_at/2`)."
  def cuts(max_length \\ 12), do: list_of(non_negative_integer(), max_length: max_length)

  @doc """
  Arbitrary JSON values, as a misbehaving provider or proxy might send,
  with object keys drawn from `keys`.
  """
  def json_value(keys) do
    tree(
      one_of([constant(nil), boolean(), integer(), float(), string(:printable, max_length: 6)]),
      fn leaf ->
        one_of([
          list_of(leaf, max_length: 3),
          map(list_of({keys, leaf}, max_length: 4), &Map.new/1)
        ])
      end
    )
  end

  @doc """
  A provider's streamed answer: `{chunks, message, model}`, the decoded
  chunks in order and the message and model they should fold into.
  Reasoning comes first, then text, then each tool call's deltas, then a
  last chunk with the finish reason and maybe usage.
  """
  def streamed_answer do
    gen all(
          model <- member_of(["m", "accounts/x/models/y", nil]),
          reasoning <- list_of(string(:utf8, min_length: 1, max_length: 6), max_length: 3),
          text <- list_of(string(:utf8, min_length: 1, max_length: 6), max_length: 4),
          ncalls <- integer(0..3),
          calls <- fixed_list(for(i <- 0..(ncalls - 1)//1, do: streamed_call(i))),
          finish <- member_of(["stop", "tool_calls", "length", nil]),
          usage <- one_of([constant(nil), usage()])
        ) do
      chunks =
        Enum.map(reasoning, &delta_chunk(%{"reasoning_content" => &1})) ++
          Enum.map(text, &delta_chunk(%{"content" => &1})) ++
          Enum.flat_map(calls, &call_chunks/1) ++
          [last_chunk(finish, usage)]

      chunks = if model, do: [Map.put(hd(chunks), "model", model) | tl(chunks)], else: chunks
      {chunks, folded_message(reasoning, text, calls), model}
    end
  end

  defp streamed_call(index) do
    gen all(
          name <- member_of(["Bash", "ViewImage"]),
          fragments <- list_of(string(:utf8, max_length: 5), max_length: 3)
        ) do
      {index, "call_#{index}", name, fragments}
    end
  end

  defp usage do
    fixed_map(%{
      "prompt_tokens" => non_negative_integer(),
      "completion_tokens" => non_negative_integer()
    })
  end

  defp delta_chunk(delta), do: %{"choices" => [%{"index" => 0, "delta" => delta}]}

  # The first delta names the call; the rest add argument fragments.
  defp call_chunks({index, id, name, fragments}) do
    [first | rest] = if fragments == [], do: [""], else: fragments

    head = %{
      "index" => index,
      "id" => id,
      "type" => "function",
      "function" => %{"name" => name, "arguments" => first}
    }

    tail = for fragment <- rest, do: %{"index" => index, "function" => %{"arguments" => fragment}}
    for delta <- [head | tail], do: delta_chunk(%{"tool_calls" => [delta]})
  end

  defp last_chunk(finish, nil),
    do: %{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => finish}]}

  defp last_chunk(finish, usage), do: Map.put(last_chunk(finish, nil), "usage", usage)

  defp folded_message(reasoning, text, calls) do
    reasoning = Enum.join(reasoning)

    %{
      "role" => "assistant",
      "content" => Message.parts(Enum.join(text)),
      "reasoning" => if(reasoning == "", do: nil, else: reasoning),
      "tool_calls" =>
        for {_index, id, name, fragments} <- calls do
          %{"id" => id, "name" => name, "arguments" => Enum.join(fragments)}
        end
    }
  end
end
