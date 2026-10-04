defmodule PhotonWeb.ModelProxyControllerTest do
  use PhotonWeb.ConnCase, async: false

  alias PhotonCore.LLM.SSE

  @body %{
    "model" => "whatever",
    "stream" => true,
    "messages" => [
      %{"role" => "system", "content" => "s"},
      %{"role" => "user", "content" => "$ echo hi"}
    ]
  }

  test "rejects requests without the node token", %{conn: conn} do
    conn = post(conn, ~p"/node/llm/v1/chat/completions", @body)
    assert conn.status == 401
  end

  test "answers with the mock model as a Chat Completions stream", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> Photon.NodeAuth.token())
      |> post(~p"/node/llm/v1/chat/completions", @body)

    assert conn.status == 200
    {payloads, _} = SSE.parse("", conn.resp_body)
    assert List.last(payloads) == "[DONE]"

    calls =
      for p <- payloads,
          p != "[DONE]",
          choice <- Jason.decode!(p)["choices"],
          call <- choice["delta"]["tool_calls"] || [],
          do: call["function"]

    assert [%{"name" => "Bash", "arguments" => args}] = calls
    assert Jason.decode!(args) == %{"command" => "echo hi"}
  end
end
