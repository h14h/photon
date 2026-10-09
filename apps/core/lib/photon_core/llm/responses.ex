defmodule PhotonCore.LLM.Responses do
  @moduledoc """
  The OpenAI Responses API adapter, which Sign in with ChatGPT uses: one
  streamed HTTP request to `<base_url>/responses`, with the signed-in
  user's access token. It does the I/O, handing each event to `on_event`
  in the calling process as it arrives; the wire format is pure, in
  `Responses.Request` and `Responses.Response`.
  """

  # The HTTP adapter. Its children, the wire format, are pure.
  use Boundary,
    type: :strict,
    deps: [
      PhotonCore,
      PhotonCore.LLM.Error,
      PhotonCore.LLM.HTTPError,
      PhotonCore.LLM.SSE,
      Jason,
      Req
    ]

  alias PhotonCore.LLM
  alias PhotonCore.LLM.{Error, HTTPError}
  alias PhotonCore.LLM.Responses.{Request, Response}

  @receive_timeout 180_000

  @doc "Runs one request, with no retries. See `PhotonCore.LLM.stream/3`."
  @spec stream(LLM.request(), LLM.config(), LLM.on_event()) ::
          {:ok, LLM.response()} | {:error, Error.t()}
  def stream(request, config, on_event) do
    case Req.post(options(request, config, on_event)) do
      {:ok, %Req.Response{status: 200} = resp} ->
        resp |> fold() |> Response.finish(&missing_call_id/1)

      {:ok, %Req.Response{} = resp} ->
        retry_after = Req.Response.get_header(resp, "retry-after")
        {:error, HTTPError.from_response(resp.status, error_body(resp), retry_after)}

      {:error, exception} ->
        {:error, Error.new(:transport, Exception.message(exception), retryable: true)}
    end
  end

  defp options(request, config, on_event) do
    [
      url: String.trim_trailing(config[:base_url] || "", "/") <> "/responses",
      json: Request.encode(request, config),
      headers: [{"authorization", "Bearer " <> (config[:api_key] || "")} | config[:headers] || []],
      receive_timeout: config[:receive_timeout] || @receive_timeout,
      retry: false,
      decode_body: false,
      into: &collect(&1, &2, on_event)
    ] ++ Map.get(config, :req_options, [])
  end

  # Req calls this with each chunk of the body. An answer is folded as it
  # streams and its events reported at once; an error body is kept whole.
  defp collect({:data, data}, {req, %Req.Response{status: 200} = resp}, on_event) do
    {stream, events} = resp |> fold() |> Response.feed(data)
    Enum.each(events, on_event)
    {:cont, {req, Req.Response.put_private(resp, :photon_answer, stream)}}
  end

  defp collect({:data, data}, {req, resp}, _on_event) do
    body = [Req.Response.get_private(resp, :photon_error_body, []), data]
    {:cont, {req, Req.Response.put_private(resp, :photon_error_body, body)}}
  end

  defp fold(resp), do: Req.Response.get_private(resp, :photon_answer, Response.new())

  defp error_body(resp) do
    case IO.iodata_to_binary(Req.Response.get_private(resp, :photon_error_body, [])) do
      "" when is_binary(resp.body) -> resp.body
      body -> body
    end
  end

  # The impure half of naming a call the model left unnamed: the name has to
  # be unique across the conversation.
  defp missing_call_id(index), do: "call_#{index}_#{System.unique_integer([:positive])}"
end
