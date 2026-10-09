defmodule PhotonWeb.AuthTest do
  @moduledoc "Who may open the GUI, in each of `Photon.Auth`'s modes."

  use PhotonWeb.ConnCase, async: false

  @moduletag :durable

  import Phoenix.LiveViewTest

  alias Photon.{FakeTailscale, NodeKeys}

  describe "with a password" do
    setup do
      Photon.TestConfig.put_env(:photon, :auth_mode, :password)
      Photon.TestConfig.put_env(:photon, :password, "s3cret")
    end

    defp basic(conn, password),
      do: put_req_header(conn, "authorization", Plug.BasicAuth.encode_basic_auth("me", password))

    test "asks for the password, and remembers a correct one in the session", %{conn: conn} do
      denied = get(conn, ~p"/")
      assert denied.status == 401
      assert get_resp_header(denied, "www-authenticate") == [~s(Basic realm="Photon")]
      assert get(basic(conn, "wrong"), ~p"/").status == 401

      signed_in = get(basic(conn, "s3cret"), ~p"/")
      assert signed_in.status == 200
      assert {:ok, _view, _html} = live(recycle(signed_in), ~p"/")
    end

    test "guards Blip's images like the pages", %{conn: conn} do
      assert get(conn, ~p"/blip/images/e_none/0").status == 401

      signed_in = get(basic(conn, "s3cret"), ~p"/")
      assert get(recycle(signed_in), ~p"/blip/images/e_none/0").status == 404
    end

    test "refuses a session that isn't signed in, over HTTP and LiveView", %{conn: conn} do
      conn = conn |> Plug.Test.init_test_session(%{"photon_auth" => "stale"})
      assert get(conn, ~p"/").status == 401

      socket = %Phoenix.LiveView.Socket{}

      assert {:halt, _} =
               PhotonWeb.Auth.on_mount(:default, %{}, %{"photon_auth" => "stale"}, socket)

      assert {:cont, _} =
               PhotonWeb.Auth.on_mount(
                 :default,
                 %{},
                 %{"photon_auth" => Photon.Auth.session_token()},
                 socket
               )
    end

    test "points the installer at https when a TLS proxy forwarded the request", %{conn: conn} do
      conn =
        %{conn | host: "hub.fly.dev", port: 8080} |> put_req_header("x-forwarded-proto", "https")

      script = get(conn, "/node/install.sh").resp_body
      assert script =~ "HUB_HTTP='https://hub.fly.dev'"
      assert script =~ "wss://hub.fly.dev/node/websocket"
    end

    test "keeps health checks, the installer and binaries open", %{conn: conn} do
      assert get(conn, "/healthz").resp_body == "ok\n"
      assert get(conn, "/node/install.sh").status == 200
      assert get(conn, "/node/download/photon-node-nope").status == 404
    end

    test "takes pages over websockets only, never long-poll", %{conn: conn} do
      assert get(conn, "/live/longpoll").status == 404
    end
  end

  describe "with tailscale" do
    @moduletag :tmp_dir

    # Requests come through the hub's own TLS proxy, which forwards the
    # client's tailnet address.
    defp from(conn, ip), do: put_req_header(conn, "x-forwarded-for", ip)

    # Every page has Blip over it, a LiveView of its own. In a browser it
    # joins over the page's websocket, with the page's connect info, but
    # LiveViewTest gives a nested LiveView none. So the LiveView check is
    # made on Blip by itself: it runs the same on_mount check as the pages.
    defp live_blip(conn), do: live_isolated(conn, PhotonWeb.BlipLive)

    # LiveViewTest takes the websocket's connect info from the conn unless
    # it's given its own: here, a websocket from somewhere else.
    defp live_from(conn, ip) do
      Plug.Conn.put_private(conn, :live_view_connect_info, %{
        peer_data: %{address: {127, 0, 0, 1}, port: 443, ssl_cert: nil},
        x_headers: [{"x-forwarded-for", ip}]
      })
    end

    setup %{tmp_dir: dir} do
      Photon.TestConfig.put_env(:photon, :auth_mode, :tailscale)
      Photon.TestConfig.put_env(:photon, :tailscale_users, ["me@github"])

      FakeTailscale.install!(dir, %{
        "100.64.0.10" => {"nLaptop", "laptop", "me@github"},
        "100.64.0.11" => {"nBox", "box", "me@github"},
        "100.64.0.12" => {"nFriend", "friends-laptop", "friend@github"},
        "100.64.0.13" => {"nCi", "ci", nil}
      })

      :ok
    end

    test "lets your own device in, over HTTP and LiveView", %{conn: conn} do
      assert get(from(conn, "100.64.0.10"), ~p"/").status == 200
      assert {:ok, _view, _html} = live_blip(from(conn, "100.64.0.10"))
    end

    defp make_box_a_node, do: NodeKeys.issue("box", device: %{device: "nBox", device_name: "box"})

    test "keeps out a machine that runs a node", %{conn: conn} do
      {:ok, _key} = make_box_a_node()

      denied = get(from(conn, "100.64.0.11"), ~p"/")
      assert denied.status == 403
      assert denied.resp_body =~ "box runs a Photon node"
    end

    test "keeps a node's machine out while its key is replaced", %{conn: conn} do
      {:ok, _key} = make_box_a_node()
      {:ok, _key} = NodeKeys.issue("box")

      assert get(from(conn, "100.64.0.11"), ~p"/").status == 403
    end

    test "closes a page that was open on a machine when it becomes a node", %{conn: conn} do
      {:ok, view, _html} = live_blip(from(conn, "100.64.0.11"))

      {:ok, _key} = make_box_a_node()

      assert_redirect(view, "/")
    end

    test "checks an open page again every minute", %{conn: conn, tmp_dir: dir} do
      {:ok, view, _html} = live_blip(from(conn, "100.64.0.10"))
      send(view.pid, :auth_recheck)
      assert render(view)

      # The laptop has since been tagged, so it's no one's to let in.
      FakeTailscale.install!(dir, %{"100.64.0.10" => {"nLaptop", "laptop", nil}})
      send(view.pid, :auth_recheck)

      assert_redirect(view, "/")
    end

    test "keeps out other people, tagged devices, and what isn't on the tailnet", %{conn: conn} do
      assert get(from(conn, "100.64.0.12"), ~p"/").resp_body =~ "belongs to friend@github"
      assert get(from(conn, "100.64.0.13"), ~p"/").resp_body =~ "ci is a tagged device"
      assert get(from(conn, "203.0.113.9"), ~p"/").status == 403
    end

    test "keeps out the hub machine itself, which has no tailnet identity to check", %{
      conn: conn
    } do
      assert get(conn, ~p"/").status == 403
    end

    test "checks the LiveView connection on its own", %{conn: conn} do
      {:ok, _key} = make_box_a_node()

      # The page loads from the laptop, but the websocket comes from the node.
      conn = conn |> from("100.64.0.10") |> live_from("100.64.0.11")
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/")
    end

    test "with a password too, your device skips it and anyone else is asked for it", %{
      conn: conn
    } do
      Photon.TestConfig.put_env(:photon, :auth_mode, :tailscale_or_password)
      Photon.TestConfig.put_env(:photon, :password, "s3cret")

      assert get(from(conn, "100.64.0.10"), ~p"/").status == 200
      assert {:ok, _view, _html} = live_blip(from(conn, "100.64.0.10"))

      assert get(from(conn, "203.0.113.9"), ~p"/").status == 401
      stranger = conn |> from("203.0.113.9") |> basic("s3cret") |> get(~p"/")
      assert stranger.status == 200
      assert {:ok, _view, _html} = live(recycle(stranger), ~p"/")
    end

    test "with a password too, won't take the password from a tailnet address it can't name",
         %{conn: conn} do
      Photon.TestConfig.put_env(:photon, :auth_mode, :tailscale_or_password)
      Photon.TestConfig.put_env(:photon, :password, "s3cret")

      # 100.64.0.99 is a tailnet address the stand-in tailscale can't name.
      denied = conn |> from("100.64.0.99") |> basic("s3cret") |> get(~p"/")
      assert denied.status == 403
      assert denied.resp_body =~ "couldn't tell which of your devices"
    end

    test "with a password too, still keeps out a machine that runs a node", %{conn: conn} do
      Photon.TestConfig.put_env(:photon, :auth_mode, :tailscale_or_password)
      Photon.TestConfig.put_env(:photon, :password, "s3cret")
      {:ok, _key} = make_box_a_node()

      denied = conn |> from("100.64.0.11") |> basic("s3cret") |> get(~p"/")
      assert denied.status == 403
      assert denied.resp_body =~ "box runs a Photon node"
    end

    test "without a list of logins, lets in whoever owns the hub machine", %{
      conn: conn,
      tmp_dir: dir
    } do
      Photon.TestConfig.delete_env(:photon, :tailscale_users)

      status = %{
        "Self" => %{"UserID" => 7, "DNSName" => "hub.example.ts.net."},
        "User" => %{"7" => %{"LoginName" => "me@github"}}
      }

      FakeTailscale.install!(dir, %{"100.64.0.10" => {"nLaptop", "laptop", "me@github"}}, status)
      assert get(from(conn, "100.64.0.10"), ~p"/").status == 200
    end
  end
end
