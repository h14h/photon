defmodule PhotonWeb.NodeAuthPlug do
  @moduledoc """
  Checks a node's key on the model relay (`/node/llm/...`) before its body
  is read, so nobody without a key can make the hub parse one. The key is
  the bearer token, checked by `Photon.NodeKeys` against where the request
  came from (`PhotonWeb.ClientIP`). A valid one goes on with the node's ID
  in `conn.assigns.node_id` and its body parsed here, up to 32 MB (a whole
  conversation, images included); the endpoint's own parser, after this,
  takes only small bodies. Anything else gets a 401 in the relay's error
  format. Other paths pass untouched.
  """

  @relay_body Plug.Parsers.init(
                parsers: [:json],
                pass: ["*/*"],
                length: 32_000_000,
                json_decoder: Jason
              )

  import Plug.Conn

  alias PhotonCore.LLM.{Error, Relay}
  alias PhotonWeb.ClientIP

  @spec init(term()) :: term()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(%Plug.Conn{path_info: ["node", "llm" | _]} = conn, _opts) do
    origin = ClientIP.identify(conn.remote_ip, conn.req_headers)

    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, node_id, _generation} <-
           Photon.NodeKeys.authenticate(token, origin, require_tailnet: Photon.Auth.tailnet?()) do
      conn |> assign(:node_id, node_id) |> Plug.Parsers.call(@relay_body)
    else
      {:error, reason} -> refuse(conn, reason)
      _no_key -> refuse(conn, "no node key")
    end
  end

  def call(conn, _opts), do: conn

  defp refuse(conn, reason) do
    body = Jason.encode_to_iodata!(%{"error" => Relay.encode_error(Error.new(:config, reason))})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end
end
