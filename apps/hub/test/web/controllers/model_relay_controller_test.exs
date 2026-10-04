defmodule PhotonWeb.ModelRelayControllerTest do
  @moduledoc "The model relay nodes use, answered by the scripted model."

  use PhotonWeb.ConnCase, async: false

  alias Photon.ChatGPTStub
  alias PhotonCore.LLM.Relay
  alias PhotonCore.Message

  @request %{system: "s", messages: [Message.user("$ echo hi")], cache_key: "ns_1"}

  defp relay(conn, token \\ Photon.NodeAuth.token()) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post(~p"/node/llm/stream", Jason.encode!(Relay.body(@request)))
  end

  # The node's side of the stream.
  defp read(body) do
    {stream, events} = Relay.Wire.feed(Relay.Wire.new(), body)
    {Relay.Wire.finish(stream), events}
  end

  test "refuses requests without the node token, saying why", %{conn: conn} do
    conn = relay(conn, "not-the-token")
    assert conn.status == 401
    assert %{"error" => %{"message" => "invalid node token"}} = json_response(conn, 401)
  end

  test "runs the node's request and streams it back in the relay's format", %{conn: conn} do
    conn = relay(conn)

    assert conn.status == 200
    assert {{:ok, response}, events} = read(conn.resp_body)
    assert [%{"name" => "Bash", "arguments" => args}] = response["message"]["tool_calls"]
    assert Jason.decode!(args) == %{"command" => "echo hi"}
    assert [{:tool_call, 0, "Bash", _} | _] = Enum.filter(events, &(elem(&1, 0) == :tool_call))
  end

  test "without a ChatGPT sign-in, a node is told so", %{conn: conn} do
    ChatGPTStub.reset!()
    Application.put_env(:photon, :mock_model, false)
    on_exit(fn -> Application.put_env(:photon, :mock_model, true) end)

    conn = relay(conn)

    assert %{"error" => %{"message" => "The hub isn't signed in with ChatGPT."}} =
             json_response(conn, 503)
  end
end
