defmodule PhotonNode.ConfigTest do
  @moduledoc "Node settings from options (which win over app config and the environment)."

  use ExUnit.Case, async: true

  alias PhotonNode.Config

  defp config(overrides \\ []) do
    Config.new(
      Keyword.merge([token: "t", node_id: "n", data_dir: "/tmp/photon-config-test"], overrides)
    )
  end

  test "the workspace defaults to one inside the data directory" do
    assert %Config{workspace: "/tmp/photon-config-test/workspace", heartbeat_ms: 600_000} =
             config()

    assert Config.sessions_dir(config()) == "/tmp/photon-config-test/sessions"
  end

  test "the heartbeat takes a non-negative integer, or keeps its default" do
    assert config(heartbeat_ms: 250).heartbeat_ms == 250
    assert config(heartbeat_ms: "0").heartbeat_ms == 0
    assert config(heartbeat_ms: "-5").heartbeat_ms == 600_000
    assert config(heartbeat_ms: "soon").heartbeat_ms == 600_000
  end

  test "model requests go to the hub that serves the websocket" do
    secure = config(server: "wss://hub.example:4443/node/websocket")
    assert Config.llm_base_url(secure) == "https://hub.example:4443/node/llm"

    plain = config(server: "ws://127.0.0.1:4000/node/websocket")
    assert Config.llm_base_url(plain) == "http://127.0.0.1:4000/node/llm"
  end
end
