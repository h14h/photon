defmodule Photon.NodesTest do
  @moduledoc "The order the hub lists connected nodes in."

  use Photon.Case, async: true

  alias Photon.Nodes

  test "puts the local node first, then sorts by ID" do
    nodes = [%{"id" => "zed"}, %{"id" => "local"}, %{"id" => "abe"}]
    assert Enum.map(Nodes.sort(nodes), & &1["id"]) == ["local", "abe", "zed"]
  end
end
