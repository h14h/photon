import Config

# Standalone node settings come from the environment; see PhotonNode.Config.
config :photon_node, autostart: config_env() != :test

# A session's coordinator tags its log lines with the session ID.
config :logger, :default_formatter, metadata: [:session]

import_config "#{config_env()}.exs"
