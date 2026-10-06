import Config

# Standalone node settings come from the environment; see PhotonNode.Config.
config :photon_node, autostart: config_env() != :test

# A shell operation's process tags its log lines with the operation ID.
config :logger, :default_formatter, metadata: [:op]

import_config "#{config_env()}.exs"
