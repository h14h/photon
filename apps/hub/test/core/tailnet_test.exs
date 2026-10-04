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

  test "cached answers are good for a minute" do
    assert Tailnet.fresh?(100, 159)
    refute Tailnet.fresh?(100, 160)
  end
end
