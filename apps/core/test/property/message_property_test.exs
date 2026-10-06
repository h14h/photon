defmodule PhotonCore.Property.MessageTest do
  @moduledoc """
  Properties of `PhotonCore.Message`, and of conversations as Responses
  input.
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

  ## Conversations as Responses input

  # A conversation with machine tools: prompts, answers that make a call or
  # only talk, and the calls' results (text, text with an image, as
  # view_image returns, or a note that the call still runs), sometimes
  # followed by an answer that reports the result.
  defp conversation do
    gen all(rounds <- list_of(round(), min_length: 1, max_length: 3)) do
      rounds
      |> Enum.with_index()
      |> Enum.flat_map(fn {round, i} -> messages(round, i) end)
    end
  end

  defp round do
    fixed_map(%{
      prompt: member_of(["$ echo hi", "view a.png", "hello", "help"]),
      call?: boolean(),
      tool: member_of(["shell", "view_image"]),
      result: member_of([:text, :image, :running]),
      report?: boolean()
    })
  end

  defp messages(%{call?: false} = round, _i),
    do: [Message.user(round.prompt), Message.assistant("Hello.")]

  defp messages(round, i) do
    call = %{
      "id" => "call_#{i}",
      "name" => round.tool,
      "arguments" => Jason.encode!(%{"machine" => "local", "command" => round.prompt})
    }

    report = if round.report?, do: [Message.assistant("Done: output #{i}.")], else: []

    [
      Message.user(round.prompt),
      Message.assistant("On it.", [call]),
      Message.tool_result(call["id"], result_parts(round.result, i))
    ] ++ report
  end

  defp result_parts(:text, i), do: [Message.text("output #{i}")]

  defp result_parts(:image, _i),
    do: [Message.text("an image"), Message.image("image/png", "QUJD")]

  defp result_parts(:running, _i), do: [Message.text("Tool call is still running.")]

  property "every conversation encodes as Responses input without raising" do
    check all(messages <- conversation(), max_runs: 150) do
      assert is_list(Request.encode_messages(messages))
    end
  end
end
