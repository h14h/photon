defmodule PhotonCore.LLM.ChatCompletions do
  @moduledoc """
  The OpenAI Chat Completions adapter: one streamed HTTP request.
  Fireworks, OpenAI, OpenRouter and Ollama all speak it, as does the hub's
  model proxy for nodes.

  This module is the boundary and does the I/O: it posts the request with
  `Req`, feeds the body to `ChatCompletions.Response` chunk by chunk as it
  arrives, and hands each event to `on_event` in the calling process. The
  wire format itself is pure and lives in two modules:

    * `ChatCompletions.Request` builds the body and converts
      `PhotonCore.Message` conversations to the wire form and back
    * `ChatCompletions.Response` folds the SSE stream into one assistant
      message, renders one as SSE, and reads HTTP errors

  `decode_messages/1`, `to_sse/1` and `encode_messages/1` delegate to them,
  so callers keep one module to name.
  """

  # The HTTP adapter. Its children, the wire format, are pure.
  use Boundary,
    type: :strict,
    deps: [PhotonCore, PhotonCore.LLM.Error, PhotonCore.LLM.SSE, Jason, Req]

  alias PhotonCore.LLM
  alias PhotonCore.LLM.ChatCompletions.{Request, Response}
  alias PhotonCore.LLM.Error
  alias PhotonCore.Message

  @receive_timeout 180_000

  @doc "Runs one request, with no retries. See `PhotonCore.LLM.stream/3`."
  @spec stream(LLM.request(), LLM.config(), LLM.on_event()) ::
          {:ok, LLM.response()} | {:error, Error.t()}
  def stream(request, config, on_event) do
    case Req.post(options(request, config, on_event)) do
      {:ok, %Req.Response{status: 200} = resp} ->
        resp |> answer() |> Response.finish(&missing_call_id/1)

      {:ok, %Req.Response{} = resp} ->
        retry_after = Req.Response.get_header(resp, "retry-after")
        {:error, Response.http_error(resp.status, error_body(resp), retry_after)}

      {:error, exception} ->
        {:error, Error.new(:transport, Exception.message(exception), retryable: true)}
    end
  end

  defp options(request, config, on_event) do
    [
      url: String.trim_trailing(config[:base_url] || "", "/") <> "/chat/completions",
      json: Request.encode(request, config),
      headers: headers(config),
      receive_timeout: config[:receive_timeout] || @receive_timeout,
      retry: false,
      decode_body: false,
      into: &collect(&1, &2, on_event)
    ] ++ Map.get(config, :req_options, [])
  end

  defp headers(config) do
    case config[:api_key] do
      key when key in [nil, ""] -> []
      key -> [{"authorization", "Bearer " <> key}]
    end
  end

  # Req calls this with each chunk of the body. An answer is folded as it
  # streams and its events reported at once; an error body is kept whole.
  defp collect({:data, data}, {req, %Req.Response{status: 200} = resp}, on_event) do
    {answer, events} = resp |> answer() |> Response.feed(data)
    Enum.each(events, on_event)
    {:cont, {req, Req.Response.put_private(resp, :photon_answer, answer)}}
  end

  defp collect({:data, data}, {req, resp}, _on_event) do
    body = [Req.Response.get_private(resp, :photon_error_body, []), data]
    {:cont, {req, Req.Response.put_private(resp, :photon_error_body, body)}}
  end

  defp answer(resp), do: Req.Response.get_private(resp, :photon_answer, Response.new())

  defp error_body(resp) do
    case IO.iodata_to_binary(Req.Response.get_private(resp, :photon_error_body, [])) do
      "" when is_binary(resp.body) -> resp.body
      body -> body
    end
  end

  # The impure half of naming a call the provider left unnamed: the name
  # has to be unique across the conversation.
  defp missing_call_id(index), do: "call_#{index}_#{System.unique_integer([:positive])}"

  ## The wire format, for callers that convert without a request

  @doc false
  @spec encode_messages([Message.t()]) :: [Request.wire_message()]
  defdelegate encode_messages(messages), to: Request

  @doc """
  Reads Chat Completions messages back into `PhotonCore.Message` form. The
  hub uses it to answer proxied node requests with the mock model. See
  `PhotonCore.LLM.ChatCompletions.Request.decode_messages/1`.
  """
  @spec decode_messages(term()) :: [Message.t()]
  defdelegate decode_messages(messages), to: Request

  @doc """
  Renders a finished response as a Chat Completions SSE stream. See
  `PhotonCore.LLM.ChatCompletions.Response.to_sse/1`.
  """
  @spec to_sse(LLM.response()) :: iolist()
  defdelegate to_sse(response), to: Response
end
