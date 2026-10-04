defmodule PhotonWeb.ModelRelayControllerTest do
  @moduledoc "The model relay nodes use, answered by the scripted model."

  use PhotonWeb.ConnCase, async: false

  alias Photon.{ChatGPTStub, FakeTailscale, NodeKeys}
  alias PhotonCore.LLM.Relay
  alias PhotonCore.Message

  @request %{system: "s", messages: [Message.user("$ echo hi")], cache_key: "ns_1"}

  # A node somewhere off the tailnet (the tests run no tailscale) unless a
  # test says otherwise.
  setup %{conn: conn} do
    {:ok, key} = NodeKeys.issue("box")
    %{conn: %{conn | remote_ip: {10, 0, 0, 5}}, key: key}
  end

  defp relay(conn, token, body \\ Jason.encode!(Relay.body(@request))) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post(~p"/node/llm/stream", body)
  end

  # The node's side of the stream.
  defp read(body) do
    {stream, events} = Relay.Wire.feed(Relay.Wire.new(), body)
    {Relay.Wire.finish(stream), events}
  end

  test "refuses requests without a node's key, saying why", %{conn: conn} do
    conn = relay(conn, "not-a-key")
    assert %{"error" => %{"message" => "unknown node key"}} = json_response(conn, 401)
  end

  test "refuses a stranger before reading what it sent, however large", %{conn: conn} do
    too_big = String.duplicate("x", 33_000_000)
    assert relay(conn, "not-a-key", too_big).status == 401
  end

  @tag :tmp_dir
  test "takes a key only from the machine it's tied to", %{conn: conn, key: key, tmp_dir: dir} do
    FakeTailscale.install!(dir, %{
      "100.64.0.10" => {"nBox", "box", "me@github"},
      "100.64.0.11" => {"nOther", "other", "me@github"}
    })

    through_proxy = fn ip ->
      %{conn | remote_ip: {127, 0, 0, 1}} |> put_req_header("x-forwarded-for", ip)
    end

    assert relay(through_proxy.("100.64.0.10"), key).status == 200

    assert %{"error" => %{"message" => "box's key belongs to box, not other"}} =
             json_response(relay(through_proxy.("100.64.0.11"), key), 401)
  end

  test "runs the node's request and streams it back in the relay's format", %{
    conn: conn,
    key: key
  } do
    conn = relay(conn, key)

    assert conn.status == 200
    assert {{:ok, response}, events} = read(conn.resp_body)
    assert [%{"name" => "Bash", "arguments" => args}] = response["message"]["tool_calls"]
    assert Jason.decode!(args) == %{"command" => "echo hi"}
    assert [{:tool_call, 0, "Bash", _} | _] = Enum.filter(events, &(elem(&1, 0) == :tool_call))
  end

  test "without a ChatGPT sign-in, a node is told so", %{conn: conn, key: key} do
    ChatGPTStub.reset!()
    Application.put_env(:photon, :mock_model, false)
    on_exit(fn -> Application.put_env(:photon, :mock_model, true) end)

    conn = relay(conn, key)

    assert %{"error" => %{"message" => "The hub isn't signed in with ChatGPT."}} =
             json_response(conn, 503)
  end
end
