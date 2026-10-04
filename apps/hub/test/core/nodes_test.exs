defmodule Photon.NodesTest do
  @moduledoc "Which nodes the hub lists, and in what order."

  use Photon.Case, async: true

  alias Photon.Nodes

  test "lists connected nodes first, then nodes known only from their sessions" do
    online = [%{"id" => "box", "platform" => "linux"}]
    sessions = [session(node_id: "nas"), session(node_id: "box"), session(node_id: "nas")]

    assert Nodes.roster(online, sessions) == [
             %{id: "box", online: true, info: hd(online)},
             %{id: "nas", online: false, info: nil}
           ]
  end

  test "puts the local node first, then sorts by ID" do
    nodes = [%{"id" => "zed"}, %{"id" => "local"}, %{"id" => "abe"}]
    assert Enum.map(Nodes.sort(nodes), & &1["id"]) == ["local", "abe", "zed"]
  end
end
