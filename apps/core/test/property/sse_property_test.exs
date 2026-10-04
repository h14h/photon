defmodule PhotonCore.Property.SSETest do
  @moduledoc """
  Properties of `PhotonCore.LLM.SSE.parse/2`: what it yields must not depend
  on how the byte stream was cut into chunks.
  """

  use PhotonCore.Case, async: true
  use ExUnitProperties

  alias PhotonCore.Generators

  # Chunks are fed one at a time with `parse_sse/1`, the way the response
  # fold feeds them, after `split_at/2` cuts the stream.

  ## Generators

  # Payloads as a provider sends them: JSON text, so never a raw CR or LF.
  defp payload do
    one_of([
      constant("[DONE]"),
      map(
        map(
          list_of({string(:alphanumeric, max_length: 4), string(:utf8, max_length: 8)},
            max_length: 3
          ),
          &Map.new/1
        ),
        &Jason.encode!/1
      ),
      map(string(:utf8, max_length: 10), &Jason.encode!/1)
    ])
  end

  defp field_line do
    one_of([
      map(payload(), &{:data, "data: " <> &1, &1}),
      map(payload(), &{:data, "data:" <> &1, &1}),
      constant({:other, ": keep-alive"}),
      constant({:other, "event: message"}),
      constant({:other, "id: 42"}),
      constant({:other, "retry: 1000"})
    ])
  end

  # A well-formed stream: events of field lines, every line ended by LF or
  # CRLF, each event ended by a blank line. Returns the text and the data
  # payloads a correct parser yields.
  defp framed_stream do
    gen all(
          events <- list_of(list_of(field_line(), min_length: 1, max_length: 3), max_length: 6),
          crlf? <- boolean(),
          mixed <- list_of(boolean(), length: 64)
        ) do
      newline = fn index ->
        if(Enum.at(mixed, rem(index, 64)) and crlf?, do: "\r\n", else: "\n")
      end

      {text, expected, _} =
        Enum.reduce(events, {"", [], 0}, fn lines, {text, expected, i} ->
          {event_text, i} =
            Enum.reduce(lines, {"", i}, fn line, {acc, i} ->
              line_text = elem(line, 1)
              {acc <> line_text <> newline.(i), i + 1}
            end)

          data = for {:data, _, payload} <- lines, do: payload
          expected = if data == [], do: expected, else: expected ++ [Enum.join(data, "\n")]
          {text <> event_text <> newline.(i), expected, i + 1}
        end)

      {text, expected}
    end
  end

  # Arbitrary text over SSE's syntax, including bare carriage returns.
  @pieces ["data:", "data: ", "x", "{}", " ", ":", "\r", "\n", "\r\n", "é", "[DONE]"]
  defp soup do
    gen(all(pieces <- list_of(member_of(@pieces), max_length: 30), do: Enum.join(pieces)))
  end

  ## Properties

  property "a well-formed stream yields its payloads however it is chunked" do
    check all(
            {text, expected} <- framed_stream(),
            cuts <- Generators.cuts(),
            max_runs: 300
          ) do
      assert {^expected, ""} = SSE.parse("", text)
      assert {^expected, ""} = parse_sse(split_at(text, cuts))
    end
  end

  property "any byte stream yields the same payloads however it is chunked" do
    check all(
            text <- soup(),
            cuts <- Generators.cuts(),
            max_runs: 300
          ) do
      # Terminate the stream so every event is complete.
      text = text <> "\n\n"
      {whole, _} = SSE.parse("", text)
      {chunked, _} = parse_sse(split_at(text, cuts))
      assert chunked == whole, "chunks: #{inspect(split_at(text, cuts))}"
    end
  end

  property "parse never raises on arbitrary bytes" do
    check all(
            text <- one_of([soup(), binary(max_length: 40)]),
            cuts <- Generators.cuts(),
            max_runs: 300
          ) do
      {data, rest} = parse_sse(split_at(text, cuts))
      assert is_list(data) and is_binary(rest)
    end
  end
end
