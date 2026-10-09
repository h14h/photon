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

  describe "gui_access/2" do
    @facts %{
      identity: {:ok, @laptop},
      tailnet_address?: true,
      logins: [@me],
      node_devices: MapSet.new(),
      signed_in?: false
    }

    defp access(mode, facts), do: Auth.gui_access(mode, Map.merge(@facts, Map.new(facts)))

    test "lets in your own device in either tailscale mode" do
      assert access(:tailscale, []) == :ok
      assert access(:tailscale_or_password, []) == :ok
    end

    test "in :tailscale, a refused device is refused whatever the session" do
      assert {:error, "laptop belongs to friend@github" <> _} =
               access(:tailscale,
                 identity: {:ok, %{@laptop | login: "friend@github"}},
                 signed_in?: true
               )

      assert {:error, "Photon only opens" <> _} =
               access(:tailscale, identity: :error, tailnet_address?: false, signed_in?: true)
    end

    test "with a password too, a device that isn't yours may use a signed-in session" do
      other = {:ok, %{@laptop | login: "friend@github"}}

      assert access(:tailscale_or_password, identity: other, signed_in?: true) == :ok
      assert access(:tailscale_or_password, identity: other) == {:error, :not_device}

      off_tailnet = [identity: :error, tailnet_address?: false]
      assert access(:tailscale_or_password, off_tailnet ++ [signed_in?: true]) == :ok
      assert access(:tailscale_or_password, off_tailnet) == {:error, :not_device}
    end

    test "with a password too, a machine that runs a node is refused even signed in" do
      assert {:error, "laptop runs a Photon node" <> _} =
               access(:tailscale_or_password,
                 node_devices: MapSet.new(["nLaptop"]),
                 signed_in?: true
               )
    end

    test "with a password too, a tailnet address tailscale couldn't name is told to retry" do
      assert access(:tailscale_or_password, identity: :error, signed_in?: true) ==
               {:error, "Photon couldn't tell which of your devices this is. Try again."}
    end
  end

  test "lets nobody in when it doesn't know whose devices to trust" do
    assert {:error, "No Tailscale login is allowed in" <> _} =
             Auth.check_device({:ok, @laptop}, [], MapSet.new())
  end
end
