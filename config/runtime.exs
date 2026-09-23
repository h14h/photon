import Config

if data_dir = System.get_env("PHOTON_DATA_DIR") do
  config :photon, data_dir: data_dir
end

# Nodes on other machines need to reach the server: PHOTON_BIND=0.0.0.0
if bind = System.get_env("PHOTON_BIND") do
  {:ok, ip} = bind |> String.to_charlist() |> :inet.parse_address()
  config :photon, PhotonWeb.Endpoint, http: [ip: ip]
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

  config :photon, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # The GUI always needs a password in production; see PhotonWeb.Auth.
  config :photon, :auth, true

  # Nodes use the tailnet when the hub is on one, otherwise this public URL.
  config :photon, fallback_url: "https://#{host}"

  config :photon, PhotonWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    # Its public host and its own tailnet name; see PhotonWeb.Origin.
    check_origin: {PhotonWeb.Origin, :allowed?, []},
    http: [
      # IPv6 and IPv4, on all interfaces.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base
end

# The GUI password: PHOTON_PASSWORD, else one generated on first boot (prod).
if password = System.get_env("PHOTON_PASSWORD") do
  config :photon, :auth, true
  config :photon, :password, password
end

# Skip the password for requests from peers on the hub's tailnet.
if System.get_env("PHOTON_TRUST_TAILNET") in ~w(1 true) do
  config :photon, :trust_tailnet, true
end
