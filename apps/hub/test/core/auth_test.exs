defmodule Photon.AuthTest do
  @moduledoc "Which devices `:tailscale` mode lets into the GUI."

  use Photon.Case, async: true

  alias Photon.Auth

  @me "me@github"
  @laptop %{device: "nLaptop", device_name: "laptop", login: @me, tags: []}

  defp check(identity, node_devices \\ []),
    do: Auth.check_device(identity, [@me], MapSet.new(node_devices))

  test "lets in your own device" do
    assert check({:ok, @laptop}) == :ok
  end

  test "keeps out what isn't on the tailnet, tagged devices and other people" do
    assert {:error, "Photon only opens on your devices on its tailnet."} = check(:error)

    assert {:error, "ci is a tagged device" <> _} =
             check({:ok, %{@laptop | device_name: "ci", login: nil, tags: ["tag:ci"]}})

    assert {:error, "laptop belongs to friend@github" <> _} =
             check({:ok, %{@laptop | login: "friend@github"}})
  end

  test "keeps out your own machines that run nodes" do
    assert {:error, "laptop runs a Photon node" <> _} = check({:ok, @laptop}, ["nLaptop"])
  end

  test "lets nobody in when it doesn't know whose devices to trust" do
    assert {:error, "No Tailscale login is allowed in" <> _} =
             Auth.check_device({:ok, @laptop}, [], MapSet.new())
  end
end
