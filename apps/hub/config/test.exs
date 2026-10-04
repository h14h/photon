import Config

config :photon,
  data_dir: Path.expand("../_build/test-data", __DIR__),
  local_node: false,
  # Tests start the harness themselves, inside the database sandbox.
  start_durable: false

# Tests run serially against a real database file, cleared before each test:
# the harness's own processes then use ordinary pooled connections.
config :photon, Photon.Repo,
  database: Path.expand("../_build/test-data/photon-test.db", __DIR__),
  pool_size: 5

config :photon_node, llm: %{provider: "mock", script: PhotonCore.LLM.MockAgent}

# Blip and the node relay answer with the scripted models, not ChatGPT; the
# account's requests to OpenAI go to a stub (Photon.ChatGPTStub).
config :photon, :mock_model, true

# Tests never run the machine's own tailscale; they name a stand-in with
# PHOTON_TAILSCALE when they need one.
config :photon, :find_tailscale, false
config :photon, Photon.ChatGPT, req_options: [plug: {Req.Test, Photon.ChatGPT}]

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :photon, PhotonWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "IFz8fczcsV1bi7JSRRP0IbDv+GtK3YZvK6QUtt/XBbzB99aeR529GO0I7VHJBV4e",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Harness tests use their own conversation profile alongside the assistant's.
config :photon, Photon.Durable,
  profiles: %{"assistant" => Photon.Assistant, "test" => Photon.TestProfile},
  kinds: %{"node_watch" => Photon.Assistant.NodeWatch, "routine" => Photon.Assistant.Routine}
