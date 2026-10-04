defmodule PhotonWeb.ModelProxyController do
  @moduledoc """
  The model endpoint nodes use: `POST /node/llm/v1/chat/completions`,
  authenticated with the node token as a bearer token.

  It forwards the request to the provider in the hub's settings, with the
  hub's key and current model, and streams the answer back unchanged. So
  nodes need no credentials, and changing the model in settings applies to
  every node session's next turn. With the mock provider it answers with
  `PhotonCore.LLM.MockAgent`.
  """

  use PhotonWeb, :controller

  require Logger

  alias Photon.Settings
  alias PhotonCore.LLM
  alias PhotonCore.LLM.ChatCompletions

  @spec chat(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def chat(conn, params) do
    if authorized?(conn) do
      settings = Settings.load()

      case settings["provider"] do
        "mock" -> mock(conn, params)
        _ -> forward(conn, params, settings)
      end
    else
      conn |> put_status(401) |> json(%{"error" => %{"message" => "invalid node token"}})
    end
  end

  defp authorized?(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> Photon.NodeAuth.valid?(token)
      _ -> false
    end
  end

  defp mock(conn, params) do
    request = %{
      messages: ChatCompletions.decode_messages(params["messages"] || []),
      tools: params["tools"] || []
    }

    {:ok, response} = LLM.stream(request, %{provider: "mock", script: PhotonCore.LLM.MockAgent})

    conn
    |> put_resp_content_type("text/event-stream")
    |> send_resp(200, ChatCompletions.to_sse(response))
  end

  defp forward(conn, params, settings) do
    {url, options} = provider_request(params, settings)

    case Req.post(url, options) do
      {:ok, resp} -> stream_back(conn, resp)
      {:error, exception} -> unreachable(conn, exception)
    end
  end

  # The request to the provider: the node's body with the hub's model and
  # reasoning setting, and the hub's key.
  defp provider_request(params, settings) do
    config = Settings.llm_config(settings, nil)
    body = params |> Map.put("model", Settings.model(settings)) |> reasoning(config, settings)

    options = [
      json: body,
      headers: authorization(config.api_key),
      into: :self,
      retry: false,
      receive_timeout: 600_000
    ]

    {String.trim_trailing(config.base_url || "", "/") <> "/chat/completions", options}
  end

  defp reasoning(body, %{send_reasoning_effort: send?}, settings) when send? not in [nil, false],
    do: Map.put(body, "reasoning_effort", settings["reasoning"])

  defp reasoning(body, _config, _settings), do: Map.delete(body, "reasoning_effort")

  defp authorization(key) when key in [nil, ""], do: []
  defp authorization(key), do: [{"authorization", "Bearer " <> key}]

  defp stream_back(conn, resp) do
    content_type =
      List.first(Req.Response.get_header(resp, "content-type")) || "text/event-stream"

    conn = conn |> put_resp_header("content-type", content_type) |> send_chunked(resp.status)
    Enum.reduce_while(resp.body, conn, &send_chunk/2)
  end

  defp send_chunk(data, conn) do
    case chunk(conn, data) do
      {:ok, conn} -> {:cont, conn}
      {:error, _} -> {:halt, conn}
    end
  end

  defp unreachable(conn, exception) do
    Logger.warning("model proxy: #{Exception.message(exception)}")

    conn
    |> put_status(502)
    |> json(%{
      "error" => %{
        "message" => "the hub couldn't reach the model: " <> Exception.message(exception)
      }
    })
  end
end
