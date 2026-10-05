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
      password; a machine that runs a node is refused either way.
    * `:off` - open.

  In the tailscale modes a connected page is checked again whenever node
  keys change (a machine that becomes a node loses the pages it had open)
  and every minute (so a device retagged or given away doesn't keep one).
  The hook does this for every LiveView, from where the connection came
  from, remembered at mount in `:auth_client`.
  """

  import Plug.Conn

  alias Photon.{Auth, NodeKeys}
  alias PhotonWeb.ClientIP

  @session_key "photon_auth"
  @recheck_ms 60_000

  @spec init(term()) :: term()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(conn, _opts) do
    case Auth.mode() do
      :off -> conn
      :password -> password_check(conn)
      mode -> device_check(conn, mode)
    end
  end

  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont | :halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, session, socket) do
    case Auth.mode() do
      :off -> {:cont, socket}
      :password -> continue_if(signed_in?(session), socket)
      mode -> live_device_check(socket, mode, signed_in?(session))
    end
  end

  defp continue_if(true, socket), do: {:cont, socket}
  defp continue_if(false, socket), do: {:halt, Phoenix.LiveView.redirect(socket, to: "/")}

  ## Tailscale

  defp device_check(conn, mode) do
    client = ClientIP.client(conn.remote_ip, conn.req_headers)

    case {decide(client, mode, false), mode} do
      {:ok, _mode} -> conn
      {{:error, :not_device}, :tailscale_or_password} -> password_check(conn)
      {{:error, reason}, _mode} -> forbid(conn, reason)
    end
  end

  defp forbid(conn, reason) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(403, message(reason) <> "\n")
    |> halt()
  end

  # The first, static render already went through the plug; the websocket
  # that follows is checked again, since it is a connection of its own, and
  # then again as node keys change and every minute.
  defp live_device_check(socket, mode, signed_in) do
    if Phoenix.LiveView.connected?(socket) do
      client = live_client(socket)
      # Before deciding, so a change can't slip in between.
      :ok = NodeKeys.subscribe()

      if decide(client, mode, signed_in) == :ok do
        :ok = schedule_recheck()

        {:cont,
         socket
         |> Phoenix.Component.assign(auth_client: client, auth_signed_in: signed_in)
         |> Phoenix.LiveView.attach_hook(:auth_recheck, :handle_info, &recheck(&1, &2, mode))}
      else
        continue_if(false, socket)
      end
    else
      {:cont, socket}
    end
  end

  defp live_client(socket) do
    case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
      %{address: address} ->
        headers = Phoenix.LiveView.get_connect_info(socket, :x_headers) || []
        ClientIP.client(address, headers)

      nil ->
        nil
    end
  end

  defp recheck({:node_keys_changed, _node}, socket, mode),
    do: {:halt, still_allowed(socket, mode)}

  defp recheck(:auth_recheck, socket, mode) do
    :ok = schedule_recheck()
    {:halt, still_allowed(socket, mode)}
  end

  defp recheck(_message, socket, _mode), do: {:cont, socket}

  defp still_allowed(socket, mode) do
    %{auth_client: client, auth_signed_in: signed_in} = socket.assigns

    if decide(client, mode, signed_in) == :ok,
      do: socket,
      else: Phoenix.LiveView.redirect(socket, to: "/")
  end

  defp schedule_recheck do
    # The timer is never cancelled: it fires once, and the next is set then.
    _timer = Process.send_after(self(), :auth_recheck, @recheck_ms)
    :ok
  end

  # Whether a client may in: its device, or (with a password too) a signed-in
  # session, but never a machine that runs a node. `{:error, :not_device}`
  # leaves room for the password.
  defp decide(client, mode, signed_in) do
    identity =
      case ClientIP.whois(client) do
        :local -> :error
        other -> other
      end

    node_devices = NodeKeys.node_devices()

    case {Auth.check_device(identity, Auth.tailscale_logins(), node_devices), mode} do
      {:ok, _mode} ->
        :ok

      {{:error, reason}, :tailscale} ->
        {:error, reason}

      {{:error, reason}, :tailscale_or_password} ->
        if unnamed_tailnet_address?(client, identity),
          do: {:error, "Photon couldn't tell which of your devices this is. Try again."},
          else: password_fallback(identity, node_devices, signed_in, reason)
    end
  end

  # A tailnet address tailscale couldn't name (it failed, say) isn't a
  # stranger to ask for the password: it may be a node, so it waits.
  defp unnamed_tailnet_address?(client, :error), do: ClientIP.tailnet?(client)
  defp unnamed_tailnet_address?(_client, _identity), do: false

  defp password_fallback({:ok, %{device: device}}, node_devices, signed_in, reason) do
    cond do
      MapSet.member?(node_devices, device) -> {:error, reason}
      signed_in -> :ok
      true -> {:error, :not_device}
    end
  end

  defp password_fallback(_identity, _node_devices, true = _signed_in, _reason), do: :ok

  defp password_fallback(_identity, _node_devices, false = _signed_in, _reason),
    do: {:error, :not_device}

  defp message(:not_device), do: "Photon only opens on your devices on its tailnet."
  defp message(reason), do: reason

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
