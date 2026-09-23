defmodule PhotonWeb.AuthTest do
  use PhotonWeb.ConnCase

  import Phoenix.LiveViewTest

  setup do
    Application.put_env(:photon, :auth, true)
    Application.put_env(:photon, :password, "s3cret")

    on_exit(fn ->
      for key <- [:auth, :password, :trust_tailnet], do: Application.delete_env(:photon, key)
      System.delete_env("PHOTON_TAILSCALE")
    end)
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

  @tag :tmp_dir
  test "lets tailnet peers in only when tailscale confirms them", %{conn: conn, tmp_dir: dir} do
    Application.put_env(:photon, :trust_tailnet, true)
    tailscale = Path.join(dir, "tailscale")
    System.put_env("PHOTON_TAILSCALE", tailscale)

    # 100.64.0.9 is a tailnet-style address, but only whois decides.
    File.write!(tailscale, "#!/bin/sh\nexit 1\n")
    File.chmod!(tailscale, 0o755)
    stranger = %{conn | remote_ip: {100, 64, 0, 9}}
    assert get(stranger, ~p"/").status == 401

    File.write!(tailscale, "#!/bin/sh\n[ \"$1 $2\" = \"whois 100.64.0.10\" ]\n")
    peer = %{conn | remote_ip: {100, 64, 0, 10}}
    assert get(peer, ~p"/").status == 200
  end
end
