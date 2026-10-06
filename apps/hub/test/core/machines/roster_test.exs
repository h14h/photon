defmodule Photon.Machines.RosterTest do
  @moduledoc "Which machines the hub knows, and the state of each."

  use Photon.Case, async: true

  alias Photon.Machines.Roster

  @ops ["ops:1"]

  defp online(id, capabilities \\ @ops),
    do: %{"id" => id, "platform" => "linux", "capabilities" => capabilities}

  describe "build/3" do
    test "local first, then connected machines, then known offline ones, each by ID" do
      infos = [online("zed"), online("local"), online("abe")]

      assert Roster.build(infos, ["nas", "box", "zed"], true) == [
               %{id: "local", online: true, info: online("local")},
               %{id: "abe", online: true, info: online("abe")},
               %{id: "zed", online: true, info: online("zed")},
               %{id: "box", online: false, info: nil},
               %{id: "nas", online: false, info: nil}
             ]
    end

    test "lists local first and offline when the hub runs its own node and it isn't connected" do
      assert Roster.build([online("mm1")], ["mm1", "nas"], true) == [
               %{id: "local", online: false, info: nil},
               %{id: "mm1", online: true, info: online("mm1")},
               %{id: "nas", online: false, info: nil}
             ]
    end

    test "leaves local out when the hub doesn't run its own node" do
      assert Roster.build([], ["nas"], false) == [%{id: "nas", online: false, info: nil}]
    end

    test "lists a machine once, however often it is known" do
      assert Roster.build([], ["nas", "nas", "local"], true) == [
               %{id: "local", online: false, info: nil},
               %{id: "nas", online: false, info: nil}
             ]
    end
  end

  describe "status/4" do
    test "a connected machine that speaks the op protocol is online" do
      assert Roster.status("mm1", online("mm1"), [], false) == :online
      assert Roster.status("local", online("local", ["x", "ops:1"]), [], true) == :online
    end

    test "a connected machine without ops:1 is outdated" do
      assert Roster.status("mm1", online("mm1", ["sessions"]), ["mm1"], false) == :outdated
      assert Roster.status("mm1", %{"id" => "mm1"}, ["mm1"], false) == :outdated
    end

    test "a known machine that isn't connected is offline" do
      assert Roster.status("nas", nil, ["nas"], false) == :offline
    end

    test "a machine the hub doesn't know is unknown" do
      assert Roster.status("nope", nil, ["nas"], true) == :unknown
    end

    test "local is offline, not unknown, when the hub runs its own node" do
      assert Roster.status("local", nil, [], true) == :offline
      assert Roster.status("local", nil, [], false) == :unknown
    end
  end
end
