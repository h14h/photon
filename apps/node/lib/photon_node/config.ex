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
  | `:heartbeat_ms` | `PHOTON_HEARTBEAT_MS` | 600000 (ten minutes; 0 disables) |
  | `:link` | none | `PhotonNode.Connection` |

  `:link` is the module the harness announces records and live data
  through (`PhotonNode.Harness.Link`); only a host embedding the node
  would change it.

  Model requests go through the hub (`llm_base_url/1`), which holds the
  provider credentials, so a node never needs an API key.
  """

  use Boundary, type: :strict, deps: []

  @enforce_keys [:server, :token, :node_id, :data_dir, :workspace]
  defstruct [
    :server,
    :token,
    :node_id,
    :data_dir,
    :workspace,
    heartbeat_ms: 600_000,
    link: PhotonNode.Connection
  ]

  @type t :: %__MODULE__{
          server: String.t(),
          token: String.t(),
          node_id: String.t(),
          data_dir: String.t(),
          workspace: String.t(),
          heartbeat_ms: non_neg_integer(),
          link: module()
        }

  @env %{
    server: "PHOTON_SERVER",
    token: "PHOTON_NODE_TOKEN",
    node_id: "PHOTON_NODE_ID",
    data_dir: "PHOTON_NODE_DATA",
    workspace: "PHOTON_NODE_WORKSPACE",
    heartbeat_ms: "PHOTON_HEARTBEAT_MS"
  }

  @doc """
  The node's settings from `opts`, falling back to app config and then the
  environment. Raises without a token.
  """
  @spec new(keyword()) :: t()
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
      heartbeat_ms: integer(get.(:heartbeat_ms), 600_000),
      link: Keyword.get(opts, :link, PhotonNode.Connection)
    }
  end

  @doc "Session logs: `<id>.jsonl`, plus `operations/<id>/` for command output."
  @spec sessions_dir(t()) :: String.t()
  def sessions_dir(config), do: Path.join(config.data_dir, "sessions")

  @doc "The hub's model relay, reached through the same host as the websocket."
  @spec llm_base_url(t()) :: String.t()
  def llm_base_url(config) do
    uri = URI.parse(config.server)
    scheme = if uri.scheme == "wss", do: "https", else: "http"
    URI.to_string(%URI{scheme: scheme, host: uri.host, port: uri.port, path: "/node/llm"})
  end

  @doc "This machine's hostname."
  @spec hostname() :: String.t()
  def hostname do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end

  defp integer(nil, default), do: default
  defp integer(value, _default) when is_integer(value), do: value

  defp integer(value, default) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n >= 0 -> n
      _ -> default
    end
  end

  defp blank_nil(""), do: nil
  defp blank_nil(value), do: value
end
