defmodule PhotonWeb.OriginTest do
  use ExUnit.Case

  alias PhotonWeb.Origin

  @tag :tmp_dir
  test "allows the hub's own hosts, whatever the scheme and port", %{tmp_dir: dir} do
    status = %{
      "Self" => %{"DNSName" => "hub.example.ts.net.", "TailscaleIPs" => ["100.64.0.1"]},
      "Peer" => %{}
    }

    tailscale = Path.join(dir, "tailscale")
    File.write!(tailscale, "#!/bin/sh\ncat <<'JSON'\n#{Jason.encode!(status)}\nJSON\n")
    File.chmod!(tailscale, 0o755)
    System.put_env("PHOTON_TAILSCALE", tailscale)
    :ets.delete(Photon.Tailnet, :own_names)

    on_exit(fn ->
      System.delete_env("PHOTON_TAILSCALE")
      :ets.delete(Photon.Tailnet, :own_names)
    end)

    assert Origin.allowed?(URI.parse("https://localhost"))
    assert Origin.allowed?(URI.parse("https://hub.example.ts.net:8443"))
    assert Origin.allowed?(URI.parse("http://100.64.0.1:8080"))
    refute Origin.allowed?(URI.parse("https://evil.example.ts.net"))
    refute Origin.allowed?(URI.parse("https://evil.com"))
    refute Origin.allowed?(%URI{host: nil})
  end
end
