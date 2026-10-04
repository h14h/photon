defmodule Photon.NodeKeysTest do
  @moduledoc "Each node's own key: issued, tied to a device, checked against where it's used, revoked."

  use Photon.DataCase, async: false

  alias Photon.NodeKeys
  alias Photon.NodeKeys.Key

  @box {:ok, %{device: "nBox", device_name: "box", login: "me@github", tags: []}}
  @other {:ok, %{device: "nOther", device_name: "other", login: "me@github", tags: []}}
  @box_device %{device: "nBox", device_name: "box"}

  setup do
    NodeKeys.subscribe()
  end

  test "a key works for its node, and ties itself to the first device it's used from" do
    {:ok, key} = NodeKeys.issue("box")
    assert "pnk_" <> _ = key

    assert {:ok, "box", 1} = NodeKeys.authenticate(key, @box)
    assert NodeKeys.node_devices() == MapSet.new(["nBox"])
    assert {:ok, "box", 1} = NodeKeys.authenticate(key, @box)

    assert {:error, "box's key belongs to box, not other"} = NodeKeys.authenticate(key, @other)

    assert {:error, "box's key only works from box on the tailnet"} =
             NodeKeys.authenticate(key, :error)

    assert {:error, "box's key only works from box"} = NodeKeys.authenticate(key, :local)
  end

  test "an install over SSH ties the key to its machine before anything uses it" do
    {:ok, key} = NodeKeys.issue("box", device: @box_device)

    assert NodeKeys.node_devices() == MapSet.new(["nBox"])
    assert {:error, "box's key belongs to box, not other"} = NodeKeys.authenticate(key, @other)
    assert {:ok, "box", 1} = NodeKeys.authenticate(key, @box)
  end

  test "a new key keeps its machine counted as a node, and the old key stops working" do
    {:ok, old} = NodeKeys.issue("box", device: @box_device)
    assert NodeKeys.current?("box", 1)

    {:ok, new} = NodeKeys.issue("box")

    assert NodeKeys.node_devices() == MapSet.new(["nBox"])
    assert {:error, "unknown node key"} = NodeKeys.authenticate(old, @box)
    assert {:error, "box's key belongs to box, not other"} = NodeKeys.authenticate(new, @other)
    assert {:ok, "box", 2} = NodeKeys.authenticate(new, @box)
    refute NodeKeys.current?("box", 1)
    assert NodeKeys.current?("box", 2)
  end

  test "revoking removes the key and the machine's tie" do
    {:ok, key} = NodeKeys.issue("box", device: @box_device)

    :ok = NodeKeys.revoke("box")

    assert {:error, "unknown node key"} = NodeKeys.authenticate(key, @box)
    assert NodeKeys.node_devices() == MapSet.new()
    refute NodeKeys.current?("box", 1)
  end

  test "says so whenever a node's key changes" do
    {:ok, key} = NodeKeys.issue("box")
    assert_receive {:node_keys_changed, "box"}

    {:ok, "box", _} = NodeKeys.authenticate(key, @box)
    assert_receive {:node_keys_changed, "box"}

    :ok = NodeKeys.revoke("box")
    assert_receive {:node_keys_changed, "box"}
  end

  test "only one device can claim an untied key, however many try at once" do
    {:ok, key} = NodeKeys.issue("box")

    devices =
      for n <- 1..6,
          do: {:ok, %{device: "n#{n}", device_name: "m#{n}", login: "me@github", tags: []}}

    results =
      devices
      |> Enum.map(fn origin -> Task.async(fn -> NodeKeys.authenticate(key, origin) end) end)
      |> Task.await_many()

    assert [{:ok, "box", 1}] = Enum.filter(results, &match?({:ok, _, _}, &1))
    assert [_tied] = MapSet.to_list(NodeKeys.node_devices())
  end

  test "a hub that vouches through its tailnet refuses keys from anywhere it can't name" do
    {:ok, key} = NodeKeys.issue("box")

    assert {:error, "box's key only works from a machine on the tailnet"} =
             NodeKeys.authenticate(key, :error, require_tailnet: true)

    assert NodeKeys.node_devices() == MapSet.new()
  end

  test "a hub without a tailnet takes untied keys from wherever they come" do
    {:ok, key} = NodeKeys.issue("vps")
    assert {:ok, "vps", 1} = NodeKeys.authenticate(key, :error)
    assert NodeKeys.node_devices() == MapSet.new()
  end

  test "a key nobody used within an hour stops working" do
    {:ok, _key} = NodeKeys.issue("box")
    [%Key{expires_at: expires} = key] = NodeKeys.list()

    assert DateTime.diff(expires, DateTime.utc_now()) in 3590..3600
    assert {:bind, _} = NodeKeys.check(key, @box, DateTime.utc_now(), true)

    assert {:error, "box's key expired before any machine used it." <> _} =
             NodeKeys.check(key, @box, DateTime.add(expires, 1), true)

    {:ok, _key} = NodeKeys.issue("tied", device: @box_device)
    assert [%Key{expires_at: nil}] = Enum.filter(NodeKeys.list(), &(&1.node_id == "tied"))
  end

  test "keeps only a hash of each key" do
    {:ok, key} = NodeKeys.issue("box")
    assert [%Key{node_id: "box", key_hash: hash}] = NodeKeys.list()
    assert hash == :crypto.hash(:sha256, key)
  end

  test "the built-in node's key is good for it alone, from the hub machine" do
    token = NodeKeys.local_token()
    assert token == NodeKeys.local_token()
    assert {:ok, "local", 0} = NodeKeys.authenticate(token, :local)
    assert NodeKeys.current?("local", 0)
    assert {:error, _reason} = NodeKeys.authenticate(token, @box)
  end

  test "refuses anything that isn't a key" do
    assert {:error, "unknown node key"} = NodeKeys.authenticate("pnk_nope", :error)
    assert {:error, "no node key"} = NodeKeys.authenticate(nil, :error)
  end
end
