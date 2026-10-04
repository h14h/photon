defmodule Photon.NodeKeysTest do
  @moduledoc "Each node's own key: issued, checked against where it's used, revoked."

  use Photon.DataCase, async: false

  alias Photon.NodeKeys
  alias Photon.NodeKeys.Key

  @box {:ok, %{device: "nBox", device_name: "box", login: "me@github", tags: []}}
  @other {:ok, %{device: "nOther", device_name: "other", login: "me@github", tags: []}}

  test "a key works for its node, and ties itself to the first device it's used from" do
    {:ok, key} = NodeKeys.issue("box")
    assert "pnk_" <> _ = key

    assert {:ok, "box"} = NodeKeys.authenticate(key, @box)
    assert NodeKeys.node_devices() == MapSet.new(["nBox"])
    assert {:ok, "box"} = NodeKeys.authenticate(key, @box)

    assert {:error, "box's key belongs to box, not other"} = NodeKeys.authenticate(key, @other)

    assert {:error, "box's key only works from box on the tailnet"} =
             NodeKeys.authenticate(key, :error)

    assert {:error, "box's key only works from box"} = NodeKeys.authenticate(key, :local)
  end

  test "issuing again replaces the key and unties it, and revoking removes it" do
    {:ok, old} = NodeKeys.issue("box")
    {:ok, "box"} = NodeKeys.authenticate(old, @box)

    {:ok, new} = NodeKeys.issue("box")
    assert {:error, "unknown node key"} = NodeKeys.authenticate(old, @box)
    assert {:ok, "box"} = NodeKeys.authenticate(new, @other)
    assert NodeKeys.node_devices() == MapSet.new(["nOther"])

    :ok = NodeKeys.revoke("box")
    assert {:error, "unknown node key"} = NodeKeys.authenticate(new, @other)
    assert NodeKeys.node_devices() == MapSet.new()
  end

  test "keeps only a hash of each key" do
    {:ok, key} = NodeKeys.issue("box")
    assert [%Key{node_id: "box", key_hash: hash}] = NodeKeys.list()
    assert hash == :crypto.hash(:sha256, key)
  end

  test "a hub without a tailnet takes untied keys from wherever they come" do
    {:ok, key} = NodeKeys.issue("vps")
    assert {:ok, "vps"} = NodeKeys.authenticate(key, :error)
    assert NodeKeys.node_devices() == MapSet.new()
  end

  test "the built-in node's key is good for it alone, from the hub machine" do
    token = NodeKeys.local_token()
    assert token == NodeKeys.local_token()
    assert {:ok, "local"} = NodeKeys.authenticate(token, :local)
    assert {:error, _reason} = NodeKeys.authenticate(token, @box)
  end

  test "refuses anything that isn't a key" do
    assert {:error, "unknown node key"} = NodeKeys.authenticate("pnk_nope", :error)
    assert {:error, "no node key"} = NodeKeys.authenticate(nil, :error)
  end
end
