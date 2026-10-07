# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :photon,
  generators: [timestamp_type: :utc_datetime],
  ecto_repos: [Photon.Repo],
  # Settings, the database, secrets, and the local node's data.
  data_dir: Path.expand("../.photon", __DIR__),
  # Start a node named "local" inside the hub. Remote nodes run the
  # `apps/node` project on their own machines.
  local_node: true

# Transactions take the write lock when they begin, so two writers queue
# (busy_timeout) instead of deadlocking on a read-to-write upgrade.
config :photon, Photon.Repo,
  database: Path.expand("../.photon/photon.db", __DIR__),
  journal_mode: :wal,
  busy_timeout: 10_000,
  default_transaction_mode: :immediate,
  pool_size: 5

# What runs the assistant's conversation, and its own task kinds.
config :photon, Photon.Durable,
  profiles: %{"assistant" => Photon.Assistant, "thread" => Photon.Threads},
  kinds: %{
    "ambient" => Photon.Ambient.Timer,
    "routine" => Photon.Schedules.Routine,
    "thread_title" => Photon.Threads.Titling
  }

# A thread whose last run was stopped (or never recorded an end) reads as
# quiet once nothing has happened in it for this long (section 2.3 of
# docs/plans/step-4-blip-as-coordinator.md).
config :photon, Photon.Threads, quiet_after_hours: 72

# Ambient mode's daily review lists a thread again when it is still
# untouched this long after a review listed it (section 4.2 of
# docs/plans/step-5-ambient-mode.md).
config :photon, Photon.Ambient, review_again_days: 7

# Between two of the owner's messages, Blip can start or message threads at
# most this many times on its own, so a loop between Blip and a thread
# stops in code (section 5.4 of docs/plans/step-4-blip-as-coordinator.md).
config :photon, Photon.Assistant, unattended_limit: 10

# A thread's ask_blip call checks this often whether Blip's run went past
# its question without handling it, and if so passes it to the owner
# (section 4.6 of docs/plans/step-4-blip-as-coordinator.md).
config :photon, Photon.Questions, check_ms: 60_000

# How a machine tool call waits for its operation: it checks once a minute
# (asking an online machine to push the op again), and gives up once the
# machine has been offline for 10 minutes.
config :photon, Photon.MachineTools, check_ms: 60_000, offline_limit_ms: 600_000

# The GUI starts the embedded node itself, once the endpoint is up.
config :photon_node, autostart: false

# Configure the endpoint
config :photon, PhotonWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PhotonWeb.ErrorHTML, json: PhotonWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Photon.PubSub,
  live_view: [signing_salt: "PkJwj1so"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  photon: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  photon: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
# Durable steps tag their lines with the task ID, and the embedded node's
# shell operations with the op ID.
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :durable_task, :op]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Kept out of logs (Phoenix and LiveView event params): passwords and keys,
# and the address pasted back from a ChatGPT sign-in, which carries a
# one-time code.
config :phoenix, :filter_parameters, ["password", "secret", "token", "key", "sign_in", "code"]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
