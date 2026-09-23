import Config

# Standalone node settings come from the environment; see PhotonNode.Config.
config :photon_node, autostart: config_env() != :test

import_config "#{config_env()}.exs"
