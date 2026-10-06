defmodule PhotonWeb.NodesLiveTest do
  @moduledoc """
  The nodes page: connected nodes, and machines on the tailnet (read with a stand-in `tailscale`, in the background).
  """

  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Photon.Machines

  @moduletag :durable
  @moduletag :tmp_dir

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
        "TailscaleIPs" => ["100.64.0.2"]
      }
    }
  }

  ## Named setups

  defp fake_tailscale(%{tmp_dir: dir}) do
    tailscale = Path.join(dir, "tailscale")
    File.write!(tailscale, "#!/bin/sh\ncat <<'JSON'\n#{Jason.encode!(@status)}\nJSON\n")
    File.chmod!(tailscale, 0o755)
    System.put_env("PHOTON_TAILSCALE", tailscale)
    on_exit(fn -> System.delete_env("PHOTON_TAILSCALE") end)
    :ok
  end

  defp connected_node(_context) do
    {:ok, _} =
      Registry.register(Photon.MachineRegistry, "box", %{
        "version" => "0.1.0",
        "platform" => "linux",
        "workspace" => "/w"
      })

    :ok
  end

  defp page(%{conn: conn}) do
    {:ok, view, _html} = live(conn, ~p"/nodes")
    %{view: view}
  end

  describe "connected nodes" do
    setup [:fake_tailscale, :connected_node, :page]

    test "show with their platform, and an update badge for old builds", %{view: view} do
      assert has_element?(view, "#node-box", "update available")
      assert has_element?(view, "#node-box", "linux")
    end

    test "offer to update every outdated node at once", %{view: view} do
      render_async(view)
      assert has_element?(view, "#update-all", "Update all (1)")

      render_click(view, "update_all")
      assert has_element?(view, "#flash-error", "Couldn't update box: This hub can't reach box.")
    end

    test "update when a node leaves", %{view: view} do
      Registry.unregister(Photon.MachineRegistry, "box")
      Machines.broadcast()
      _ = render(view)
      refute has_element?(view, "#node-box")
    end
  end

  describe "machines on the tailnet" do
    setup [:fake_tailscale, :page]

    test "are read in the background", %{view: view} do
      render_async(view)
      assert has_element?(view, "#machine-box")
      assert has_element?(view, "#install-box")
    end

    test "can't be installed when nodes couldn't reach this hub", %{view: view} do
      render_async(view)
      assert has_element?(view, "#install-box[disabled]")

      render_click(view, "provision", %{"machine" => "box", "action" => "install"})
      assert has_element?(view, "#flash-error", "This hub can't reach box.")
    end

    test "are read again on refresh, and the SSH user is remembered", %{view: view} do
      render_async(view)
      render_click(view, "refresh_tailnet")
      render_async(view)
      assert has_element?(view, "#machine-box")

      view |> form("#ssh-user-form", ssh_user: " me ") |> render_change()
      assert has_element?(view, "#ssh-user[value=me]")
    end
  end

  test "without tailscale, the page says so and still offers the installer", %{
    conn: conn,
    tmp_dir: dir
  } do
    System.put_env("PHOTON_TAILSCALE", Path.join(dir, "missing"))
    on_exit(fn -> System.delete_env("PHOTON_TAILSCALE") end)

    {:ok, view, _html} = live(conn, ~p"/nodes")
    render_async(view)

    refute has_element?(view, "#machine-box")
    assert has_element?(view, "#manual-key-form")
  end

  test "an install command carries a key made for that node alone", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/nodes")
    assert has_element?(view, "#install-command-box.hidden")

    view |> form("#manual-key-form", manual: %{node_id: "no spaces"}) |> render_submit()
    assert has_element?(view, "#flash-error", "Name it with letters")

    html = view |> form("#manual-key-form", manual: %{node_id: " vps-1 "}) |> render_submit()

    # Straight to the browser, never into the page's state or its HTML.
    assert_push_event(view, "install-command", %{command: command})

    assert [_, key] =
             Regex.run(~r/PHOTON_NODE_ID=vps-1 PHOTON_NODE_TOKEN=(pnk_[\w-]+) sh/, command)

    refute html =~ key
    refute inspect(:sys.get_state(view.pid)) =~ key
    refute has_element?(view, "#install-command-box.hidden")
    assert {:ok, "vps-1", _generation} = Photon.NodeKeys.authenticate(key, :error)
  end

  test "won't make a key for the built-in node's name", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/nodes")
    view |> form("#manual-key-form", manual: %{node_id: "local"}) |> render_submit()
    assert has_element?(view, "#flash-error", "built-in node")
  end

  test "keeps removed machines out until the user lets them back in", %{conn: conn} do
    {:ok, _key} = Photon.NodeKeys.issue("old", device: %{device: "nOld", device_name: "old-box"})
    :ok = Photon.NodeKeys.revoke("old")

    {:ok, view, _html} = live(conn, ~p"/nodes")
    assert has_element?(view, "#removed-old", "old-box")

    view |> element("#forget-old") |> render_click()

    refute has_element?(view, "#removed-nodes")
    assert has_element?(view, "#flash-info", "can open the hub again")
    assert Photon.NodeKeys.node_devices() == MapSet.new()
  end
end
