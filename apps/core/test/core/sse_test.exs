defmodule PhotonCore.LLM.SSETest do
  use PhotonCore.Case, async: true

  describe "chunked input" do
    test "SSE parsing keeps partial events for the next chunk" do
      {data, rest} = SSE.parse("", "data: one\n\nda")
      assert data == ["one"]
      {data, rest} = SSE.parse(rest, "ta: two\r\n\r\n: keep-alive\n\n")
      assert data == ["two"]
      assert rest == ""
    end

    # core-sse-crlf-split: the leftover buffer was normalized twice, so a
    # payload's trailing CR depended on where the stream was cut.
    test "a CR before a CRLF gives the same payload however the stream is cut" do
      text = "data: x\r\r\n\n"
      {whole, _} = SSE.parse("", text)

      for cut <- 1..(byte_size(text) - 1) do
        <<a::binary-size(^cut), b::binary>> = text
        {chunked, _} = parse_sse([a, b])
        assert chunked == whole, "cut at #{cut}"
      end

      assert whole == ["x"]
    end

    test "the shrunk counterexample parses the same whole and cut at byte 8" do
      text = "data:\r\r\ndata:data:data:data:\n\n"
      <<a::binary-size(8), b::binary>> = text
      {whole, _rest} = parse_sse([a, b])
      {cut, _cut_rest} = SSE.parse("", text)
      assert whole == cut
    end
  end

  describe "line endings and fields" do
    test "bare CR ends a line, and a CRLF split across chunks is one line ending" do
      assert {["a", "b"], ""} = SSE.parse("", "data: a\r\rdata: b\r\n\r\n")
      assert {[], "data: a\r"} = SSE.parse("", "data: a\r")
      assert {["a"], ""} = parse_sse(["data: a\r", "\n\r", "\n"])
    end

    test "only one space after the colon is dropped, and the field name must be data" do
      assert {["  x"], ""} = SSE.parse("", "data:   x\n\n")
      assert {["data: x"], ""} = SSE.parse("", "data:data: x\n\n")
      assert {[], ""} = SSE.parse("", "datax: y\n\n")
    end

    test "an event's data lines join with newlines, and a bare data field is empty" do
      assert {["a\nb"], ""} = SSE.parse("", "data: a\ndata: b\n\n")
      assert {[""], ""} = SSE.parse("", "data\n\n")
      assert {[], ""} = SSE.parse("", "event: ping\nid: 1\n\n")
    end
  end
end
