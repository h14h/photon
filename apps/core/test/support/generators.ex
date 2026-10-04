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
  A streamed answer, as the Responses API sends it: `{events, message,
  model}`, the decoded events in order and the message and model they
  should fold into. Reasoning summary deltas come first, then text, then
  each tool call (added, argument deltas, done), then the end.
  """
  def streamed_answer do
    gen all(
          model <- member_of(["m", "gpt-6.1-sol", nil]),
          reasoning <- list_of(string(:utf8, min_length: 1, max_length: 6), max_length: 3),
          text <- list_of(string(:utf8, min_length: 1, max_length: 6), max_length: 4),
          ncalls <- integer(0..3),
          calls <- fixed_list(for(i <- 0..(ncalls - 1)//1, do: streamed_call(i))),
          usage <- one_of([constant(nil), usage()])
        ) do
      events =
        Enum.map(reasoning, &delta("response.reasoning_summary_text.delta", &1)) ++
          Enum.map(text, &delta("response.output_text.delta", &1)) ++
          Enum.flat_map(calls, &call_events/1) ++
          [
            %{
              "type" => "response.completed",
              "response" => %{"status" => "completed", "model" => model, "usage" => usage}
            }
          ]

      {events, folded_message(reasoning, text, calls), model}
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
      "input_tokens" => non_negative_integer(),
      "output_tokens" => non_negative_integer()
    })
  end

  defp delta(type, text), do: %{"type" => type, "delta" => text}

  # The message is output item 0; each call takes the next.
  defp call_events({index, id, name, fragments}) do
    item = %{"type" => "function_call", "call_id" => id, "name" => name, "arguments" => ""}

    [%{"type" => "response.output_item.added", "output_index" => index + 1, "item" => item}] ++
      for(
        fragment <- fragments,
        do: %{
          "type" => "response.function_call_arguments.delta",
          "output_index" => index + 1,
          "delta" => fragment
        }
      ) ++
      [
        %{
          "type" => "response.output_item.done",
          "output_index" => index + 1,
          "item" => %{item | "arguments" => Enum.join(fragments)}
        }
      ]
  end

  defp folded_message(reasoning, text, calls) do
    reasoning = Enum.join(reasoning)

    %{
      "role" => "assistant",
      "content" => Message.parts(Enum.join(text)),
      "reasoning" => if(reasoning == "", do: nil, else: reasoning),
      "tool_calls" =>
        for {_index, id, name, fragments} <- calls do
          %{"id" => id, "name" => name, "arguments" => Enum.join(fragments)}
        end,
      "reasoning_items" => []
    }
  end
end
