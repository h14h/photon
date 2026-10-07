import Config

if data_dir = System.get_env("PHOTON_DATA_DIR") do
  config :photon, data_dir: data_dir
  config :photon, Photon.Repo, database: Path.join(data_dir, "photon.db")
end

# Where the hub listens. In development nodes on other machines need
# PHOTON_BIND=0.0.0.0 (or the tailnet address); in production it listens on
# all interfaces unless this narrows it, e.g. to 127.0.0.1 behind a proxy.
bind_ip =
  if bind = System.get_env("PHOTON_BIND") do
    {:ok, ip} = bind |> String.to_charlist() |> :inet.parse_address()
    config :photon, PhotonWeb.Endpoint, http: [ip: ip]
    ip
  end

# The URL nodes use to reach this hub, e.g. behind `tailscale serve` or TLS.
if url = System.get_env("PHOTON_PUBLIC_URL") do
  config :photon, public_url: url
end

if dist = System.get_env("PHOTON_NODE_DIST") do
  config :photon, node_dist_dir: dist
end

if System.get_env("PHOTON_LOCAL_NODE") in ~w(0 false) do
  config :photon, local_node: false
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/photon start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :photon, PhotonWeb.Endpoint, server: true
end

config :photon, PhotonWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # PHOTON_MOCK_MODEL=1 answers with the scripted models instead of ChatGPT,
  # for working on the hub without a sign-in. Development only.
  if System.get_env("PHOTON_MOCK_MODEL") in ~w(1 true) do
    config :photon, :mock_model, true
  end

  # PHOTON_QUIET_AFTER_HOURS=<n> makes a stopped or failed thread count as
  # untouched after n hours instead of 72, so a demo's daily review has
  # something to show (0: after a second). A whole number, 0 or more;
  # anything else is ignored. Development only.
  with hours when is_binary(hours) <- System.get_env("PHOTON_QUIET_AFTER_HOURS"),
       {hours, ""} when hours >= 0 <- Integer.parse(String.trim(hours)) do
    config :photon, Photon.Threads, quiet_after_hours: hours
  end

  # Reload browser tabs when matching files change.
  config :photon, PhotonWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/photon_web/router\.ex$"E,
        ~r"lib/photon_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # Everything a deployment needs is optional: secrets are generated on first
  # boot and kept in the data directory (a volume at /data on Fly).
  data_dir = System.get_env("PHOTON_DATA_DIR") || Path.expand("~/.photon")
  config :photon, data_dir: data_dir
  config :photon, Photon.Repo, database: Path.join(data_dir, "photon.db")

  persisted_secret = fn name, bytes ->
    path = Path.join(data_dir, name)

    case File.read(path) do
      {:ok, value} when byte_size(value) > 0 ->
        String.trim(value)

      _ ->
        value = :crypto.strong_rand_bytes(bytes) |> Base.url_encode64(padding: false)
        File.mkdir_p!(data_dir)
        File.write!(path, value)
        File.chmod!(path, 0o600)
        value
    end
  end

  secret_key_base = System.get_env("SECRET_KEY_BASE") || persisted_secret.("secret_key_base", 48)
  # On Fly, the app's own hostname unless PHX_HOST says otherwise.
  fly_host = System.get_env("FLY_APP_NAME") && "#{System.get_env("FLY_APP_NAME")}.fly.dev"
  host = System.get_env("PHX_HOST") || fly_host || "localhost"

  # The GUI needs a password in production unless PHOTON_AUTH says
  # otherwise (below); see Photon.Auth.
  config :photon, :auth_mode, :password

  # Nodes use the tailnet when the hub is on one, otherwise this public URL.
  config :photon, fallback_url: "https://#{host}"

  config :photon, PhotonWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    # Its public host and its own tailnet name; see PhotonWeb.Origin.
    check_origin: {PhotonWeb.Origin, :allowed?, []},
    http: [
      # IPv6 and IPv4, on all interfaces, unless PHOTON_BIND says otherwise.
      ip: bind_ip || {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base
end

# The GUI password: PHOTON_PASSWORD, else one generated on first boot (prod).
if password = System.get_env("PHOTON_PASSWORD") do
  config :photon, :auth_mode, :password
  config :photon, :password, password
end

# Who may open the GUI (see Photon.Auth): "tailscale" (only your own
# devices on the hub's tailnet, never one that runs a node), "password",
# "tailscale,password" (your tailnet devices, else the password), or "off"
# (a hub only another login can reach). PHOTON_TRUST_TAILNET=true is the
# older name for "tailscale,password".
auth =
  System.get_env("PHOTON_AUTH") ||
    if System.get_env("PHOTON_TRUST_TAILNET") in ~w(1 true), do: "tailscale,password"

case auth do
  nil ->
    :ok

  "tailscale" ->
    config :photon, :auth_mode, :tailscale

  "password" ->
    config :photon, :auth_mode, :password

  "tailscale,password" ->
    config :photon, :auth_mode, :tailscale_or_password

  off when off in ~w(0 false off) ->
    config :photon, :auth_mode, :off

  other ->
    raise "PHOTON_AUTH must be tailscale, password, tailscale,password or off, not #{inspect(other)}"
end

# With PHOTON_AUTH=tailscale: the Tailscale logins let in (comma-separated),
# else whoever owns the hub machine.
if users = System.get_env("PHOTON_TAILSCALE_USERS") do
  config :photon, :tailscale_users, String.split(users, ~r/[\s,]+/, trim: true)
end
