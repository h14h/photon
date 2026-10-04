import Config

config :logger, level: :warning

# Node tests talk to the scripted mock model instead of a hub.
config :photon_node, llm: %{provider: "mock", script: PhotonCore.LLM.MockAgent}
