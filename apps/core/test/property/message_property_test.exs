defmodule PhotonCore.Property.MessageTest do
  @moduledoc """
  Properties of `PhotonCore.Message`, and of the mock agent seen through the
  hub's model proxy (which re-reads the wire format with `decode_messages/1`).
  """

  use PhotonCore.Case, async: true
  use ExUnitProperties

  alias PhotonCore.Generators

  defp json_value, do: Generators.json_value(string(:alphanumeric, max_length: 3))

  # What a model can write as arguments: any text at all.
  defp argument_text do
    one_of([
      constant(nil),
      constant(""),
      binary(max_length: 20),
      string(:printable, max_length: 20),
      map(json_value(), &Jason.encode!/1)
    ])
  end

  property "arguments of text (or nil) decode to {:ok, map} or {:error, text}" do
    check all(args <- argument_text(), max_runs: 300) do
      case Message.arguments(%{"id" => "c", "name" => "t", "arguments" => args}) do
        {:ok, map} -> assert is_map(map)
        {:error, reason} -> assert is_binary(reason)
      end
    end
  end

  property "arguments that are a JSON object's text decode to that object" do
    check all(
            object <-
              map(
                list_of({string(:alphanumeric, max_length: 4), json_value()}, max_length: 4),
                &Map.new/1
              ),
            max_runs: 200
          ) do
      assert {:ok, decoded} = Message.arguments(%{"arguments" => Jason.encode!(object)})
      assert decoded == object |> Jason.encode!() |> Jason.decode!()
    end
  end

  # A call as a decoded request body may carry it: any JSON value, or none.
  property "arguments never raises, whatever the call holds" do
    check all(
            args <- one_of([argument_text(), json_value()]),
            present? <- boolean(),
            max_runs: 300
          ) do
      call = if present?, do: %{"id" => "c", "arguments" => args}, else: %{"id" => "c"}
      result = Message.arguments(call)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "text_of and parts agree on plain text" do
    check all(text <- string(:utf8, max_length: 20), max_runs: 200) do
      assert Message.text_of(Message.parts(text)) == text
      assert Message.text_of(Message.user(text)) == text
    end
  end

  ## The mock agent through the hub's proxy

  # A node session's conversation with the mock agent: prompts, the calls it
  # makes, and their results (sometimes with an image, as ViewImage returns).
  defp session do
    gen all(
          prompts <-
            list_of(member_of(["$ echo hi", "view a.png", "hello", "help"]),
              min_length: 1,
              max_length: 3
            ),
          images <- list_of(boolean(), length: 3),
          running <- list_of(boolean(), length: 3)
        ) do
      prompts
      |> Enum.with_index()
      |> Enum.reduce([], fn {prompt, i}, messages ->
        messages = messages ++ [Message.user(prompt)]

        case MockAgent.respond(%{messages: messages}) do
          %{"tool_calls" => [call]} = reply ->
            parts =
              cond do
                Enum.at(running, i) ->
                  [Message.text("Tool call is still running.")]

                Enum.at(images, i) ->
                  [Message.text("an image"), Message.image("image/png", "QUJD")]

                true ->
                  [Message.text("output #{i}")]
              end

            messages ++ [reply, Message.tool_result(call["id"], parts)]

          reply ->
            messages ++ [reply]
        end
      end)
    end
  end

  # Mock call IDs are fresh each time; compare replies without them.
  defp shape(%{"tool_calls" => calls} = reply) do
    %{reply | "tool_calls" => Enum.map(calls, &Map.delete(&1, "id"))}
  end

  property "the mock agent answers the same directly and through the hub's relay" do
    check all(messages <- session(), max_runs: 150) do
      direct = MockAgent.respond(%{messages: messages})

      relayed =
        %{messages: messages}
        |> Relay.body()
        |> Jason.encode!()
        |> Jason.decode!()

      assert shape(MockAgent.respond(%{messages: relayed["messages"]})) == shape(direct)
    end
  end

  property "every conversation encodes as Responses input without raising" do
    check all(messages <- session(), max_runs: 150) do
      assert is_list(Request.encode_messages(messages))
    end
  end
end
