defmodule PhotonNode.Config do
  @moduledoc """
  Node settings. Each option can be passed to `{PhotonNode, opts}`, set under
  `config :photon_node`, or given through the environment:

  | Option | Env | Default |
  | --- | --- | --- |
  | `:server` | `PHOTON_SERVER` | `ws://127.0.0.1:4000/node/websocket` |
  | `:token` | `PHOTON_NODE_TOKEN` | required |
  | `:node_id` | `PHOTON_NODE_ID` | the hostname |
  | `:data_dir` | `PHOTON_NODE_DATA` | `~/.photon-node` |
  | `:workspace` | `PHOTON_NODE_WORKSPACE` | `<data_dir>/workspace` |
  | `:runner` | `PHOTON_RUNNER` | see `PhotonNode.Runner.executable/0` |
  """

  @enforce_keys [:server, :token, :node_id, :data_dir, :workspace]
  defstruct [:server, :token, :node_id, :data_dir, :workspace, :runner]

  @env %{
    server: "PHOTON_SERVER",
    token: "PHOTON_NODE_TOKEN",
    node_id: "PHOTON_NODE_ID",
    data_dir: "PHOTON_NODE_DATA",
    workspace: "PHOTON_NODE_WORKSPACE",
    runner: "PHOTON_RUNNER"
  }

  def new(opts) do
    get = fn key ->
      Keyword.get(opts, key) || Application.get_env(:photon_node, key) ||
        blank_nil(System.get_env(@env[key]))
    end

    token = get.(:token) || raise ArgumentError, "PhotonNode needs a token: set PHOTON_NODE_TOKEN"
    data_dir = Path.expand(get.(:data_dir) || "~/.photon-node")

    %__MODULE__{
      server: get.(:server) || "ws://127.0.0.1:4000/node/websocket",
      token: token,
      node_id: get.(:node_id) || hostname(),
      data_dir: data_dir,
      workspace: Path.expand(get.(:workspace) || Path.join(data_dir, "workspace")),
      runner: get.(:runner)
    }
  end

  def runner_sessions_dir(config), do: Path.join(config.data_dir, "runner-sessions")
  def runner_logs_dir(config), do: Path.join(config.data_dir, "runner-logs")
  def events_dir(config), do: Path.join(config.data_dir, "node-events")

  @doc "The GUI's mock model, reached through the same host as the websocket."
  def mock_base_url(config) do
    uri = URI.parse(config.server)
    scheme = if uri.scheme == "wss", do: "https", else: "http"
    URI.to_string(%URI{scheme: scheme, host: uri.host, port: uri.port, path: "/mock/v1"})
  end

  def hostname do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end

  defp blank_nil(""), do: nil
  defp blank_nil(value), do: value
end
