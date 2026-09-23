defmodule Photon.NodeInstallTest do
  # Runs the real install script and SSH flow against a sandboxed $HOME, with
  # stand-ins for ssh, systemctl, launchctl and the node binary.
  use ExUnit.Case

  alias Photon.{NodeDist, Provision}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    home = Path.join(dir, "home")
    bin = Path.join(dir, "bin")
    dist = Path.join(dir, "dist")
    File.mkdir_p!(home)
    File.mkdir_p!(bin)
    File.mkdir_p!(dist)

    # Service managers just record how they were called.
    for tool <- ~w(systemctl loginctl launchctl) do
      shim(Path.join(bin, tool), ~s(echo "#{tool} $*" >> "#{dir}/calls"))
    end

    # Like the real binary, a wrapper that runs the long-lived process as a child.
    fake_node = """
    case "$1" in --version) echo 9.9.9-test ;; *) sleep 30 & wait ;; esac
    """

    for target <- NodeDist.targets(),
        do: shim(Path.join(dist, "photon-node-" <> target), fake_node)

    shim(Path.join(dir, "fake-node"), fake_node)

    # "ssh": drop the options and host, run the remote command here.
    shim(Path.join(bin, "ssh"), ~s(for last; do :; done\nHOME="#{home}" exec sh -c "$last"))

    Application.put_env(:photon, :node_dist_dir, dist)
    on_exit(fn -> Application.delete_env(:photon, :node_dist_dir) end)

    env = [{"HOME", home}, {"PATH", bin <> ":/usr/bin:/bin"}, {"SHELL", "/bin/sh"}]
    %{dir: dir, home: home, bin: bin, env: env, calls: Path.join(dir, "calls")}
  end

  defp shim(path, body) do
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
  end

  defp script, do: NodeDist.install_script("http://hub.example.ts.net:4000")

  defp install(ctx, extra) do
    File.cp!(Path.join(ctx.dir, "fake-node"), Path.join(ctx.dir, "upload"))

    env = [
      {"PHOTON_NODE_TOKEN", "tok"},
      {"PHOTON_NODE_ID", "box"},
      {"PHOTON_BINARY", Path.join(ctx.dir, "upload")} | extra
    ]

    System.cmd("sh", ["-c", script()], env: ctx.env ++ env, stderr_to_stdout: true)
  end

  test "points the script at the hub, and refuses shell metacharacters in the URL" do
    assert script() =~ "PHOTON_SERVER:-ws://hub.example.ts.net:4000/node/websocket"
    assert script() =~ "HUB_HTTP='http://hub.example.ts.net:4000'"
    assert_raise ArgumentError, fn -> NodeDist.install_script("http://x'; rm -rf ~; '") end
  end

  test "installs a systemd user service with the settings in a private env file", ctx do
    {out, 0} = install(ctx, [{"PHOTON_SERVICE", "systemd"}])
    assert out =~ ~s(installed photon-node 9.9.9-test as "box" (systemd)
    assert out =~ "PHOTON_INSTALL_OK"

    env_file = Path.join(ctx.home, ".config/photon-node/env")

    assert File.read!(env_file) =~
             "PHOTON_SERVER=ws://hub.example.ts.net:4000/node/websocket\nPHOTON_NODE_TOKEN=tok\nPHOTON_NODE_ID=box\n"

    assert File.stat!(env_file).mode |> Bitwise.band(0o777) == 0o600

    unit = File.read!(Path.join(ctx.home, ".config/systemd/user/photon-node.service"))
    assert unit =~ "EnvironmentFile=%h/.config/photon-node/env"
    assert unit =~ "ExecStart=%h/.local/share/photon-node/bin/photon-node"
    assert File.read!(ctx.calls) =~ "systemctl --user enable --now photon-node"
    assert File.exists?(Path.join(ctx.home, ".local/share/photon-node/bin/photon-node"))
  end

  test "installs a launchd agent whose plist is valid XML", ctx do
    {out, 0} = install(ctx, [{"PHOTON_SERVICE", "launchd"}])
    assert out =~ "PHOTON_INSTALL_OK"

    plist = Path.join(ctx.home, "Library/LaunchAgents/dev.photon.node.plist")
    {doc, _} = plist |> String.to_charlist() |> :xmerl_scan.file(quiet: true)
    assert elem(doc, 0) == :xmlElement
    assert File.read!(plist) =~ "<key>PHOTON_NODE_TOKEN</key><string>tok</string>"
    assert File.read!(ctx.calls) =~ "launchctl bootstrap gui/"
  end

  test "falls back to a background process, and uninstalls cleanly", ctx do
    {out, 0} = install(ctx, [{"PHOTON_SERVICE", "none"}])
    assert out =~ "won't restart after a reboot"
    pid = File.read!(Path.join(ctx.home, ".local/share/photon-node/node.pid")) |> String.trim()
    assert {_, 0} = System.cmd("kill", ["-0", pid])
    Process.sleep(100)
    {child, 0} = System.cmd("pgrep", ["-P", pid])

    {out, 0} =
      System.cmd("sh", ["-c", script()],
        env: ctx.env ++ [{"PHOTON_ACTION", "uninstall"}],
        stderr_to_stdout: true
      )

    assert out =~ "PHOTON_UNINSTALL_OK"
    refute File.exists?(Path.join(ctx.home, ".local/share/photon-node/bin/photon-node"))
    refute File.exists?(Path.join(ctx.home, ".config/photon-node/env"))
    Process.sleep(100)
    assert {_, 1} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
    assert {_, 1} = System.cmd("kill", ["-0", String.trim(child)], stderr_to_stdout: true)
  end

  test "fails clearly without a token", ctx do
    {out, status} = System.cmd("sh", ["-c", script()], env: ctx.env, stderr_to_stdout: true)
    assert status != 0
    assert out =~ "set PHOTON_NODE_TOKEN"
  end

  test "provisions over ssh and waits for the node to connect", ctx do
    System.put_env("PHOTON_SSH", Path.join(ctx.bin, "ssh"))
    on_exit(fn -> System.delete_env("PHOTON_SSH") end)
    Phoenix.PubSub.subscribe(Photon.PubSub, Provision.topic())

    :ok =
      Provision.run(:install,
        machine: "box",
        host: "box.example.ts.net",
        node_id: "box-test",
        base_url: "http://hub.example.ts.net:4000",
        env: %{"PHOTON_SERVICE" => "none"}
      )

    assert {:error, "already busy"} =
             Provision.run(:install,
               machine: "box",
               host: "box.example.ts.net",
               node_id: "box-test",
               base_url: "http://h:1"
             )

    # Play the part of the freshly installed node joining the hub.
    assert_receive {:provision, %{"box" => %{log: ["Waiting for box-test" <> _ | _]}}}, 5_000

    {:ok, _} =
      Registry.register(Photon.NodeRegistry, "box-test", %{
        "running" => MapSet.new(),
        "connected_at" => DateTime.utc_now(),
        "version" => "9.9.9-test",
        "platform" => "test"
      })

    Photon.Nodes.broadcast()

    assert_receive {:provision, %{"box" => %{status: :ok, log: [done | _] = log}}}, 5_000
    assert done =~ "box-test is connected"
    assert Enum.any?(log, &(&1 =~ "Uploading photon-node-linux-x86_64"))
    assert File.read!(Path.join(ctx.home, ".config/photon-node/env")) =~ "PHOTON_NODE_ID=box-test"

    System.cmd("sh", ["-c", script()], env: ctx.env ++ [{"PHOTON_ACTION", "uninstall"}])
  end

  test "reports ssh failures", ctx do
    shim(
      Path.join(ctx.bin, "ssh"),
      ~s(echo "ssh: connect to host nope port 22: Connection refused" >&2; exit 255)
    )

    System.put_env("PHOTON_SSH", Path.join(ctx.bin, "ssh"))
    on_exit(fn -> System.delete_env("PHOTON_SSH") end)
    Phoenix.PubSub.subscribe(Photon.PubSub, Provision.topic())

    :ok =
      Provision.run(:install,
        machine: "nope",
        host: "nope",
        node_id: "nope",
        base_url: "http://h:1"
      )

    assert_receive {:provision, %{"nope" => %{status: :error, log: [failure | _]}}}, 5_000
    assert failure =~ "SSH to nope failed: ssh: connect to host nope port 22: Connection refused"
  end

  test "explains ssh failures by their cause, not ssh's last line" do
    output = """
    tailscale: tailnet policy does not permit you to SSH as user "photon"
    Connection closed by UNKNOWN port 65535
    """

    assert Provision.ssh_reason(output) ==
             ~s(tailscale: tailnet policy does not permit you to SSH as user "photon". ) <>
               ~s(Set "SSH as" \(or PHOTON_SSH_USER on the hub\) to your user on that machine.)

    assert Provision.ssh_reason("banner\nssh: connect to host x port 22: Connection refused\n") =~
             "Connection refused"

    assert Provision.ssh_reason("something odd\n") == "something odd"
  end
end
