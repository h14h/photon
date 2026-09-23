defmodule Photon.TailnetTest do
  use ExUnit.Case, async: true

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
    %{self: self, peers: [box, mini, phone]} = Photon.Tailnet.parse(@status)

    assert self.dns == "hub.example.ts.net"

    assert %{name: "box", ip: "100.64.0.2", online: true, installable: true, tailscale_ssh: true} =
             box

    assert %{name: "mini", hostname: "Mac mini", installable: true, tags: ["tag:ci"]} = mini
    assert %{name: "phone", installable: false, tailscale_ssh: false} = phone
  end
end
