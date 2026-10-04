defmodule Photon.TailnetTest do
  @moduledoc "Reading `tailscale status`, and the cache rules."

  use Photon.Case, async: true

  alias Photon.Tailnet

  @status %{
    "Self" => %{
      "HostName" => "hub",
      "DNSName" => "hub.example.ts.net.",
      "OS" => "linux",
      "Online" => true,
      "TailscaleIPs" => ["100.64.0.1"]
    },
    "Peer" => %{
      "k1" => %{
        "HostName" => "box",
        "DNSName" => "box.example.ts.net.",
        "OS" => "linux",
        "Online" => true,
        "TailscaleIPs" => ["100.64.0.2", "fd7a::2"],
        "sshHostKeys" => ["ssh-ed25519 AAAA"]
      },
      "k2" => %{
        "HostName" => "localhost",
        "DNSName" => "phone.example.ts.net.",
        "OS" => "iOS",
        "Online" => false,
        "TailscaleIPs" => ["100.64.0.3"]
      },
      "k3" => %{
        "HostName" => "Mac mini",
        "DNSName" => "mini.example.ts.net.",
        "OS" => "macOS",
        "Online" => false,
        "Tags" => ["tag:ci"]
      }
    }
  }

  test "names machines by MagicDNS and orders installable online ones first" do
    %{self: self, peers: [box, mini, phone]} = Tailnet.parse(@status)

    assert self.dns == "hub.example.ts.net"

    assert %{name: "box", ip: "100.64.0.2", online: true, installable: true, tailscale_ssh: true} =
             box

    assert %{name: "mini", hostname: "Mac mini", installable: true, tags: ["tag:ci"]} = mini
    assert %{name: "phone", installable: false, tailscale_ssh: false} = phone
  end

  test "the hub's own names are its DNS name and address, blanks dropped" do
    assert Tailnet.names({:ok, Tailnet.parse(@status)}) == ["hub.example.ts.net", "100.64.0.1"]
    assert Tailnet.names({:ok, %{self: %{dns: "", ip: nil}}}) == []
    assert Tailnet.names({:error, "no tailscale"}) == []
  end

  test "the hub machine's owner is its user's login, and nobody for a tagged hub" do
    users = %{"User" => %{"7" => %{"LoginName" => "me@github"}}}
    owned = @status |> Map.merge(users) |> put_in(["Self", "UserID"], 7)

    assert Tailnet.parse(owned).owner == "me@github"
    assert Tailnet.parse(put_in(owned, ["Self", "Tags"], ["tag:server"])).owner == nil
    assert Tailnet.parse(@status).owner == nil
  end

  test "whois names the device by its stable ID, and its user unless it's tagged" do
    whois = %{
      "Node" => %{
        "StableID" => "nAbC",
        "Name" => "laptop.example.ts.net.",
        "ComputedName" => "laptop",
        "Tags" => nil
      },
      "UserProfile" => %{"LoginName" => "me@github"}
    }

    assert Tailnet.parse_whois(whois) ==
             {:ok, %{device: "nAbC", device_name: "laptop", login: "me@github", tags: []}}

    tagged = put_in(whois, ["Node", "Tags"], ["tag:ci"])
    assert {:ok, %{login: nil, tags: ["tag:ci"]}} = Tailnet.parse_whois(tagged)

    unnamed = update_in(whois["Node"], &Map.delete(&1, "ComputedName"))
    assert {:ok, %{device_name: "laptop"}} = Tailnet.parse_whois(unnamed)

    assert Tailnet.parse_whois(%{"Node" => %{"StableID" => ""}}) == :error
    assert Tailnet.parse_whois(%{}) == :error
  end

  test "cached answers are good for a minute" do
    assert Tailnet.fresh?(100, 159)
    refute Tailnet.fresh?(100, 160)
  end
end
