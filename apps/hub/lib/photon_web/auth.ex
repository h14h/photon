defmodule PhotonWeb.Auth do
  @moduledoc """
  Guards the GUI as `Photon.Auth.mode/0` says: a plug for HTTP requests
  and an `on_mount` hook for LiveView connections.

    * `:tailscale` - every request and every LiveView connection is
      checked: where it came from (`PhotonWeb.ClientIP`) goes to `tailscale
      whois`, and `Photon.Auth.check_device/3` decides. Nothing is kept in
      the session, so a cookie copied to another device opens nothing.
    * `:password` - browser Basic Auth (any username) once, then a flag in
      the session cookie.
    * `:tailscale_or_password` - your device as in `:tailscale`, else the
      password.
    * `:off` - open.
  """

  import Plug.Conn

  alias Photon.Auth
  alias PhotonWeb.ClientIP

  @session_key "photon_auth"

  @spec init(term()) :: term()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(conn, _opts) do
    case Auth.mode() do
      :off -> conn
      :tailscale -> device_check(conn)
      :password -> password_check(conn)
      :tailscale_or_password -> device_or_password_check(conn)
    end
  end

  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont | :halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, session, socket) do
    allowed =
      case Auth.mode() do
        :off -> true
        :tailscale -> live_device_allowed?(socket)
        :password -> signed_in?(session)
        :tailscale_or_password -> signed_in?(session) or live_device_allowed?(socket)
      end

    if allowed,
      do: {:cont, socket},
      else: {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
  end

  ## Tailscale

  defp device_check(conn) do
    case device_allowed(conn.remote_ip, conn.req_headers) do
      :ok ->
        conn

      {:error, reason} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(403, reason <> "\n")
        |> halt()
    end
  end

  # The first, static render already went through the plug; the websocket
  # that follows is checked again, since it is a connection of its own.
  defp live_device_allowed?(socket) do
    if Phoenix.LiveView.connected?(socket) do
      peer = Phoenix.LiveView.get_connect_info(socket, :peer_data)
      headers = Phoenix.LiveView.get_connect_info(socket, :x_headers) || []
      peer != nil and device_allowed(peer.address, headers) == :ok
    else
      true
    end
  end

  # The hub machine itself has no tailnet identity of its own to check.
  defp device_allowed(remote_ip, headers) do
    identity =
      case ClientIP.identify(remote_ip, headers) do
        :local -> :error
        other -> other
      end

    Auth.check_device(identity, Auth.tailscale_logins(), Photon.NodeKeys.node_devices())
  end

  defp device_or_password_check(conn) do
    case device_allowed(conn.remote_ip, conn.req_headers) do
      :ok -> conn
      {:error, _reason} -> password_check(conn)
    end
  end

  ## Password

  defp signed_in?(session), do: session[@session_key] == Auth.session_token()

  defp password_check(conn) do
    cond do
      get_session(conn, @session_key) == Auth.session_token() -> conn
      basic_auth_ok?(conn) -> put_session(conn, @session_key, Auth.session_token())
      true -> challenge(conn)
    end
  end

  defp basic_auth_ok?(conn) do
    case Plug.BasicAuth.parse_basic_auth(conn) do
      {_user, password} -> Auth.valid?(password)
      :error -> false
    end
  end

  defp challenge(conn) do
    conn
    |> put_resp_header("www-authenticate", ~s(Basic realm="Photon"))
    |> put_resp_content_type("text/plain")
    |> send_resp(401, "Photon needs its password. Any username works.\n")
    |> halt()
  end
end
