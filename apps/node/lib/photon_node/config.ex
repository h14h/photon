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
  | `:link` | none | `PhotonNode.Connection` |

  `:link` (see `PhotonNode.Executor.Link`) is for a host embedding the
  node, or a test.
  """

  use Boundary, type: :strict, deps: []

  @enforce_keys [:server, :token, :node_id, :data_dir, :workspace]
  defstruct [
    :server,
    :token,
    :node_id,
    :data_dir,
    :workspace,
    link: PhotonNode.Connection
  ]

  @type t :: %__MODULE__{
          server: String.t(),
          token: String.t(),
          node_id: String.t(),
          data_dir: String.t(),
          workspace: String.t(),
          link: module()
        }

  @env %{
    server: "PHOTON_SERVER",
    token: "PHOTON_NODE_TOKEN",
    node_id: "PHOTON_NODE_ID",
    data_dir: "PHOTON_NODE_DATA",
    workspace: "PHOTON_NODE_WORKSPACE"
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
      link: Keyword.get(opts, :link, PhotonNode.Connection)
    }
  end

  @doc """
  The hub's operations: `<op_id>/`, holding the executor's journal entry
  (`op.json`) and a shell command's files.
  """
  @spec ops_dir(t()) :: String.t()
  def ops_dir(config), do: Path.join(config.data_dir, "ops")

  @doc "This machine's hostname."
  @spec hostname() :: String.t()
  def hostname do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end

  defp blank_nil(""), do: nil
  defp blank_nil(value), do: value
end
