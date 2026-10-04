defmodule Photon.Provision.ScriptTest do
  @moduledoc "What provisioning sends over SSH and how it reads the answers."

  use Photon.Case, async: true

  @opts %{
    node_id: "box",
    base_url: "http://hub.example.ts.net:4000",
    env: %{"PHOTON_SERVICE" => "none"}
  }

  test "reads the probe's key=value lines, and passes other output through" do
    assert Script.parse_probe("os=Linux\narch=x86_64\nuser=me\nnoise=1\n") ==
             %{"os" => "Linux", "arch" => "x86_64", "user" => "me"}

    assert Script.parse_probe("PHOTON_INSTALL_OK\n") == "PHOTON_INSTALL_OK\n"
    assert Script.probe() =~ ~s|echo "os=$(uname -s)"|
  end

  test "describes what the probe found" do
    assert Script.describe("linux-x86_64", %{"user" => "me"}) == "linux-x86_64, user me"

    assert Script.describe("linux-x86_64", %{"user" => "me", "installed" => "photon-node 1"}) ==
             "linux-x86_64, user me, has photon-node 1"
  end

  test "hands the installer its settings on stdin, the token quoted" do
    input = Script.install_input(@opts, "to'k")

    assert input =~ "PHOTON_NODE_TOKEN='to'\\''k'; export PHOTON_NODE_TOKEN\n"
    assert input =~ "PHOTON_NODE_ID='box'; export PHOTON_NODE_ID\n"
    assert input =~ "PHOTON_SERVER='ws://hub.example.ts.net:4000/node/websocket'"
    assert input =~ "PHOTON_SERVICE='none'"
    assert input =~ ~s(PHOTON_BINARY="$HOME/.local/share/photon-node/bin/photon-node.upload")
    assert String.ends_with?(input, Photon.NodeDist.install_script(@opts.base_url))

    assert Script.uninstall_input(@opts.base_url) =~
             "PHOTON_ACTION='uninstall'; export PHOTON_ACTION\n"

    assert Script.upload() =~ ~s(cat > "$HOME/.local/share/photon-node/bin/photon-node.upload")
  end

  test "runs ssh non-interactively, through a proxy when one is set" do
    args = Script.ssh_args("me@box", "sh -s", "/tmp/c", nil)

    assert ["-o", "BatchMode=yes" | _] = args
    assert Enum.take(args, -2) == ["me@box", "sh -s"]
    assert "ControlPath=/tmp/c/%C" in args

    assert ["-o", "ProxyCommand=tailscale nc %h %p" | ^args] =
             Script.ssh_args("me@box", "sh -s", "/tmp/c", "tailscale nc %h %p")

    assert Script.ssh_args("me@box", "sh -s", "/tmp/c", "") == args
  end

  test "names the user only when there is one" do
    assert Script.target("box", "me") == "me@box"
    assert Script.target("box", nil) == "box"
    assert Script.target("box", false) == "box"
    assert Script.target("box", "") == "box"
  end

  test "explains ssh failures by their cause, not ssh's last line" do
    output = """
    tailscale: tailnet policy does not permit you to SSH as user "photon"
    Connection closed by UNKNOWN port 65535
    """

    assert Script.ssh_reason(output) ==
             ~s(tailscale: tailnet policy does not permit you to SSH as user "photon". ) <>
               ~s(Set "SSH as" \(or PHOTON_SSH_USER on the hub\) to your user on that machine.)

    assert Script.ssh_reason("banner\nssh: connect to host x port 22: Connection refused\n") =~
             "Connection refused"

    assert Script.ssh_reason("something odd\n") == "something odd"
    assert Script.ssh_reason("") == "no output"
    assert Script.last_line("a\nb\n") == "b"
    assert Script.last_line("") == "no output"
  end
end
