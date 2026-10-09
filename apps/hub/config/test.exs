import Config

# `mix test --partitions N` runs each partition in its own VM; each gets
# its own data dir and database (MIX_TEST_PARTITION is 1..N).
test_data = Path.expand("../_build/test-data#{System.get_env("MIX_TEST_PARTITION")}", __DIR__)

# A partition keeps its own record of failed tests too, which
# scripts/test-partitioned merges into the usual one.
if System.get_env("MIX_TEST_PARTITION") do
  config :ex_unit, failures_manifest_path: Path.join(test_data, ".mix_test_failures")
end

config :photon,
  data_dir: test_data,
  local_node: false,
  # Tests start the harness themselves, inside the database sandbox.
  start_durable: false

# Tests run serially against a real database file, cleared before each test:
# the harness's own processes then use ordinary pooled connections.
config :photon, Photon.Repo,
  database: Path.join(test_data, "photon-test.db"),
  pool_size: 5

# Blip answers with the scripted model, not ChatGPT; the account's requests
# to OpenAI go to a stub (Photon.ChatGPTStub).
config :photon, :mock_model, true

# Tests never run the machine's own tailscale; they name a stand-in with
# PHOTON_TAILSCALE when they need one.
config :photon, :find_tailscale, false
config :photon, Photon.ChatGPT, req_options: [plug: {Req.Test, Photon.ChatGPT}]
# Skills are fetched from a stub too, never from GitHub.
config :photon, Photon.Skills, req_options: [plug: {Req.Test, Photon.Skills}]

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

# Machine tool calls check and give up in milliseconds; a test that needs a
# call to stay parked longer sets its own limits.
config :photon, Photon.MachineTools, check_ms: 200, offline_limit_ms: 500

# An ask_blip call checks for a question Blip didn't get to in milliseconds.
config :photon, Photon.Questions, check_ms: 50

# Harness tests use their own conversation profile alongside the assistant's.
config :photon, Photon.Durable,
  profiles: %{
    "assistant" => Photon.Assistant,
    "thread" => Photon.Threads,
    "test" => Photon.TestProfile,
    "test_hooks" => Photon.TestProfile.Hooks,
    "test_workdir" => Photon.TestProfile.Workdir
  },
  kinds: %{
    "ambient" => Photon.Ambient.Timer,
    "routine" => Photon.Schedules.Routine,
    "thread_title" => Photon.Threads.Titling
  }

# Threads aren't named by the model after their first run, so no title task
# outlives a test or retitles a thread under it; the tests of titling turn
# it on.
config :photon, Photon.Threads, auto_title: false
