defmodule PhotonCore.RelayWireTest do
  @moduledoc "The relay's stream format: rendered by the hub, folded by the node."

  use PhotonCore.Case, async: true

  defp fold(pieces) do
    {stream, events} =
      Enum.reduce(pieces, {Wire.new(), []}, fn piece, {stream, events} ->
        {stream, more} = Wire.feed(stream, piece)
        {stream, events ++ more}
      end)

    {Wire.finish(stream), events}
  end

  test "every event and the answer come through as sent, however the body is cut" do
    error = Error.new(:http, "slow", status: 429, retryable: true, retry_after: 1000)
    response = %{"message" => Message.assistant("hi"), "stop" => "end_turn"}

    body =
      IO.iodata_to_binary([
        Wire.event({:reasoning, "hm"}),
        Wire.keep_alive(),
        Wire.event({:retry, 1, 1000, error}),
        Wire.event({:text, "h"}),
        Wire.event({:tool_call, 0, nil, "{}"}),
        Wire.done(response),
        Wire.event({:text, "after the end"})
      ])

    expected =
      {{:ok, response},
       [
         {:reasoning, "hm"},
         {:retry, 1, 1000, %{error | retryable: false}},
         {:text, "h"},
         {:tool_call, 0, nil, "{}"}
       ]}

    assert fold([body]) == expected
    assert fold(split_at(body, [3, 20, 41, 90, 150])) == expected
  end

  test "an error ends the stream, keeps its kind and isn't retryable again" do
    body = IO.iodata_to_binary(Wire.error(Error.new(:config, "not signed in", retryable: true)))

    assert {{:error, %Error{kind: :config, message: "not signed in", retryable: false}}, []} =
             fold([body])
  end

  test "a stream cut off before its end is worth a retry" do
    assert {{:error, %Error{retryable: true}}, [{:text, "a"}]} =
             fold([IO.iodata_to_binary(Wire.event({:text, "a"}))])
  end

  test "what it can't read is skipped, and nothing counts after the end" do
    body =
      ~s(data: {not json\n\n) <>
        ~s(data: {"type":"mystery"}\n\n) <>
        ~s(data: {"type":"text","delta":5}\n\n) <>
        IO.iodata_to_binary(Relay.done(%{"stop" => "end_turn"}))

    {stream, []} = Wire.feed(Wire.new(), body)
    assert {_stream, []} = Wire.feed(stream, IO.iodata_to_binary(Relay.event({:text, "late"})))
    assert {:ok, %{"stop" => "end_turn"}} = Wire.finish(stream)
  end

  test "an error without a message, or of an unknown kind, still reads" do
    assert %Error{kind: :stream} = Wire.decode_error(%{"kind" => "nope", "message" => "x"})
    assert %Error{kind: :stream} = Wire.decode_error("garbage")
  end
end
