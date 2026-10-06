defmodule PhotonNode.ConfigTest do
  @moduledoc "Node settings from options (which win over app config and the environment)."

  use ExUnit.Case, async: true

  alias PhotonNode.Config

  defp config(overrides \\ []) do
    Config.new(
      Keyword.merge([token: "t", node_id: "n", data_dir: "/tmp/photon-config-test"], overrides)
    )
  end

  test "the workspace and the ops directory are inside the data directory" do
    assert %Config{workspace: "/tmp/photon-config-test/workspace"} = config()
    assert Config.ops_dir(config()) == "/tmp/photon-config-test/ops"
  end

  test "a workspace option wins, expanded" do
    assert config(workspace: "/srv/../work").workspace == "/work"
  end
end
