defmodule PhotonCore.Property.ChatCompletionsTest do
  @moduledoc """
  Properties of the Chat Completions wire format, all on the pure core
  (`ChatCompletions.Request` and `ChatCompletions.Response`): message
  encoding round trips, and streamed responses folded into one message
  regardless of how the bytes arrive. The same fold over real HTTP is
  checked in `llm_stream_property_test.exs`.
  """

  use PhotonCore.Case, async: true
  use ExUnitProperties

  alias PhotonCore.Generators

  ## Message generators

  defp text, do: one_of([string(:printable, max_length: 12), member_of(["", " ", "a\n\nb"])])

  defp image do
    gen all(
          mime <- member_of(["image/png", "image/jpeg", "image/webp"]),
          data <- string(:alphanumeric, min_length: 1, max_length: 8)
        ) do
      Message.image(mime, data)
    end
  end

  defp parts, do: list_of(one_of([map(text(), &Message.text/1), image()]), max_length: 4)

  defp content, do: one_of([text(), parts()])

  defp call(id) do
    gen all(
          name <- member_of(["Bash", "ViewImage", "wait", ""]),
          args <- one_of([constant(nil), constant(""), map(text(), &Jason.encode!(%{"x" => &1}))])
        ) do
      %{"id" => id, "name" => name, "arguments" => args}
    end
  end

  defp message(index) do
    one_of([
      map(content(), &Message.user/1),
      gen all(
            text <- text(),
            n <- integer(0..3),
            calls <- fixed_list(for(i <- 1..n//1, do: call("c#{index}_#{i}")))
          ) do
        Message.assistant(text, calls)
      end,
      gen all(id <- member_of(["c#{index}", "c0_1", "c1_1"]), content <- content()) do
        Message.tool_result(id, content)
      end
    ])
  end

  defp conversation do
    gen all(
          n <- integer(0..8),
          messages <- fixed_list(for(i <- 0..(n - 1)//1, do: message(i)))
        ) do
      messages
    end
  end

  ## The meaning a message keeps on the wire, for comparison

  # What decoding should give back for one round of tool results: each
  # result's text as one part, then its images. Encoding moves the images
  # into a user message after the round, captioned with their call IDs;
  # decoding puts each back into the first result at or after the previous
  # one with that ID, so a round that repeats a call ID may regroup them.
  defp expected(messages) do
    messages
    |> Enum.chunk_by(&(&1["role"] == "tool"))
    |> Enum.flat_map(fn
      [%{"role" => "tool"} | _] = results ->
        ids = Enum.map(results, & &1["tool_call_id"])

        {owners, _} =
          for r <- results, image <- Message.images(r), reduce: {%{}, 0} do
            {owners, from} ->
              index = from + Enum.find_index(Enum.drop(ids, from), &(&1 == r["tool_call_id"]))
              {Map.update(owners, index, [image], &(&1 ++ [image])), index}
          end

        for {r, index} <- Enum.with_index(results) do
          Message.tool_result(
            r["tool_call_id"],
            Message.parts(Message.text_of(r)) ++ Map.get(owners, index, [])
          )
        end

      others ->
        Enum.map(others, &expected_one/1)
    end)
  end

  defp expected_one(%{"role" => "user", "content" => parts}) do
    if Enum.all?(parts, &match?(%{"type" => "text"}, &1)),
      do: Message.user(Message.text_of(parts)),
      else: Message.user(parts)
  end

  defp expected_one(%{"role" => "assistant"} = m) do
    calls = for c <- Message.tool_calls(m), do: %{c | "arguments" => c["arguments"] || "{}"}
    Message.assistant(Message.text_of(m), calls)
  end

  ## Round trips

  property "encoding is a fixpoint of decode-then-encode" do
    check all(messages <- conversation(), max_runs: 300) do
      wire = ChatCompletions.encode_messages(messages)
      assert ChatCompletions.encode_messages(ChatCompletions.decode_messages(wire)) == wire
    end
  end

  property "decoding an encoded conversation keeps every message's meaning" do
    check all(messages <- conversation(), max_runs: 300) do
      decoded = messages |> ChatCompletions.encode_messages() |> ChatCompletions.decode_messages()
      assert decoded == expected(messages)
    end
  end

  property "the wire form survives JSON" do
    check all(messages <- conversation(), max_runs: 200) do
      wire = ChatCompletions.encode_messages(messages)
      assert wire |> Jason.encode!() |> Jason.decode!() == wire
    end
  end

  ## Streaming

  property "a streamed answer folds into the same message however its bytes are split" do
    check all(
            {chunks, message, model} <- Generators.streamed_answer(),
            crlf? <- boolean(),
            cuts <- Generators.cuts(16),
            max_runs: 200
          ) do
      separator = if crlf?, do: "\r\n\r\n", else: "\n\n"
      keep_alive = ": keep-alive" <> separator
      body = sse_body(chunks, crlf: crlf?) <> keep_alive <> sse_body([:done], crlf: crlf?)
      {whole, events} = read_stream([body])
      assert read_stream(split_at(body, cuts)) == {whole, events}

      if message["content"] == [] and message["tool_calls"] == [] and
           List.last(chunks)["choices"] |> hd() |> Map.get("finish_reason") == nil do
        assert {:error, _} = whole
      else
        assert {:ok, response} = whole
        assert response["message"] == message
        assert response["model"] == model
      end
    end
  end

  property "the hub's mock renderer streams back the message it rendered" do
    check all(
            n <- integer(0..3),
            calls <- fixed_list(for(i <- 1..n//1, do: call("call_#{i}"))),
            text <- string(:utf8, max_length: 20),
            cuts <- Generators.cuts(8),
            max_runs: 150
          ) do
      response = %{
        "message" => Message.assistant(text, calls),
        "model" => "mock-model",
        "usage" => %{"input" => 3, "output" => 4}
      }

      body = response |> ChatCompletions.to_sse() |> IO.iodata_to_binary()

      assert {{:ok, streamed}, _events} = read_stream(split_at(body, cuts))

      expected_calls = for c <- calls, do: %{c | "arguments" => c["arguments"] || ""}
      assert streamed["message"]["content"] == Message.parts(text)
      assert streamed["message"]["tool_calls"] == expected_calls
      assert streamed["usage"]["input"] == 3 and streamed["usage"]["output"] == 4
      assert streamed["model"] == "mock-model"
    end
  end

  ## Robustness

  @chunk_keys ~w(choices delta content tool_calls index id function name arguments usage
                 finish_reason reasoning_content error model)

  # Arbitrary JSON values with the keys chunks use, as a misbehaving
  # provider or proxy might send.
  defp json_value, do: Generators.json_value(member_of(@chunk_keys))

  property "a stream of arbitrary JSON chunks returns a result instead of raising" do
    check all(chunks <- list_of(json_value(), min_length: 1, max_length: 4), max_runs: 300) do
      {result, events} = read_stream([sse_body(chunks)])
      assert match?({:ok, _}, result) or match?({:error, _}, result)
      assert is_list(events)
    end
  end

  property "decode_messages returns messages for any JSON list instead of raising" do
    check all(
            pairs <-
              list_of({member_of(~w(user assistant tool system)), json_value()}, max_length: 4),
            max_runs: 300
          ) do
      messages =
        Enum.map(pairs, fn
          {role, m} when is_map(m) -> Map.put(m, "role", role)
          {_role, other} -> other
        end)

      assert is_list(ChatCompletions.decode_messages(messages))
    end
  end
end
