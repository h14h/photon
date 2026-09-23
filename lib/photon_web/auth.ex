defmodule PhotonWeb.Auth do
  @moduledoc """
  Guards the GUI with `Photon.Auth`: a plug for HTTP requests (browser Basic
  Auth, any username) and an `on_mount` hook for LiveView connections, which
  carry the signed-in flag in the session cookie.

  With `PHOTON_TRUST_TAILNET`, requests from peers on the hub's tailnet are
  let in without a password. The peer is confirmed with `tailscale whois`,
  not by its IP range, so traffic arriving through a public proxy never
  counts.
  """

  import Plug.Conn

  alias Photon.Auth

  @session_key "photon_auth"

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      not Auth.enabled?() -> conn
      get_session(conn, @session_key) == Auth.session_token() -> conn
      Auth.trust_tailnet?() and Photon.Tailnet.peer?(conn.remote_ip) -> sign_in(conn)
      basic_auth_ok?(conn) -> sign_in(conn)
      true -> challenge(conn)
    end
  end

  def on_mount(:default, _params, session, socket) do
    if not Auth.enabled?() or session[@session_key] == Auth.session_token(),
      do: {:cont, socket},
      else: {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
  end

  defp basic_auth_ok?(conn) do
    case Plug.BasicAuth.parse_basic_auth(conn) do
      {_user, password} -> Auth.valid?(password)
      :error -> false
    end
  end

  defp sign_in(conn), do: put_session(conn, @session_key, Auth.session_token())

  defp challenge(conn) do
    conn
    |> put_resp_header("www-authenticate", ~s(Basic realm="Photon"))
    |> put_resp_content_type("text/plain")
    |> send_resp(401, "Photon needs its password. Any username works.\n")
    |> halt()
  end
end
