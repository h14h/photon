defmodule PhotonNode.Harness.ModelRequestTest do
  @moduledoc "The live events a model request streams to the hub (the pure half of `ModelRequest`)."

  use PhotonNode.Case, async: true

  alias PhotonCore.LLM

  test "text, reasoning and tool-call deltas carry their turn" do
    assert ModelRequest.live_event("t1", {:text, "Hi"}) ==
             %{"type" => "text", "turn" => "t1", "delta" => "Hi"}

    assert ModelRequest.live_event("t1", {:web_search, "ws_1", nil}) ==
             %{"type" => "web_search", "turn" => "t1", "id" => "ws_1", "action" => nil}

    assert ModelRequest.live_event("t1", {:reasoning, "hm"}) ==
             %{"type" => "reasoning", "turn" => "t1", "delta" => "hm"}

    assert ModelRequest.live_event("t1", {:tool_call, 0, "Bash", "{\"co"}) ==
             %{
               "type" => "tool_call",
               "turn" => "t1",
               "index" => 0,
               "name" => "Bash",
               "delta" => "{\"co"
             }
  end

  test "a retry says why and when" do
    error = LLM.Error.new(:http, "slow down", status: 429)

    assert ModelRequest.live_event("t1", {:retry, 2, 1000, error}) == %{
             "type" => "retry",
             "turn" => "t1",
             "attempt" => 2,
             "delay_ms" => 1000,
             "message" => "HTTP 429: slow down"
           }
  end
end
