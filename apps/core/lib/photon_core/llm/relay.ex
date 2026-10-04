defmodule PhotonCore.LLM.Relay do
  @moduledoc """
  The client for the hub's model relay, which nodes use instead of talking
  to a provider. It posts the request to `<base_url>/stream` with the
  node's token and folds the event stream the hub sends back
  (`PhotonCore.LLM.Relay.Wire`), reporting each event as it arrives.

  The hub picks the model, holds the credentials and does the retries, so a
  node needs no provider details at all, and a change of provider needs no
  change on nodes. An error the hub reports has had its retries and comes
  back as not retryable; failing to reach the hub at all is retryable.

  This module does the I/O; the format is `Relay.Wire`'s. The hub renders
  its side of the stream with `event/1`, `done/1`, `error/1`, `keep_alive/0`
  and `encode_error/1`, which delegate to it, so it names one module.
  """

  # The HTTP client; its child, the stream format, is pure.
  use Boundary,
    type: :strict,
    deps: [PhotonCore, PhotonCore.LLM.Error, PhotonCore.LLM.SSE, Jason, Req]

  alias PhotonCore.LLM
  alias PhotonCore.LLM.Error
  alias PhotonCore.LLM.Relay.Wire

  @receive_timeout 180_000

  @doc "Runs one request through the hub. See `PhotonCore.LLM.stream/3`."
  @spec stream(LLM.request(), LLM.config(), LLM.on_event()) ::
          {:ok, LLM.response()} | {:error, Error.t()}
  def stream(request, config, on_event) do
    case Req.post(options(request, config, on_event)) do
      {:ok, %Req.Response{status: 200} = resp} ->
        resp |> fold() |> Wire.finish()

      {:ok, %Req.Response{} = resp} ->
        {:error, refusal(resp.status, error_body(resp))}

      {:error, exception} ->
        {:error, Error.new(:transport, Exception.message(exception), retryable: true)}
    end
  end

  @doc "One streamed model event, as the hub sends it. See `Relay.Wire`."
  @spec event(tuple()) :: iolist()
  defdelegate event(event), to: Wire

  @doc "The finished response, which ends the stream."
  @spec done(map()) :: iolist()
  defdelegate done(response), to: Wire

  @doc "The failure that ends the stream."
  @spec error(Error.t()) :: iolist()
  defdelegate error(error), to: Wire

  @doc "A comment that keeps the connection open while nothing else comes."
  @spec keep_alive() :: String.t()
  defdelegate keep_alive, to: Wire

  @doc "An error as the stream and the hub's refusals carry it."
  @spec encode_error(Error.t()) :: map()
  defdelegate encode_error(error), to: Wire

  @doc "The JSON body the hub receives for `request`."
  @spec body(LLM.request()) :: map()
  def body(request) do
    %{
      "model" => request[:model],
      "system" => request[:system],
      "messages" => request[:messages] || [],
      "tools" => request[:tools] || [],
      "reasoning" => request[:reasoning],
      "max_tokens" => request[:max_tokens],
      "cache_key" => request[:cache_key]
    }
  end

  defp options(request, config, on_event) do
    [
      url: String.trim_trailing(config[:base_url] || "", "/") <> "/stream",
      json: body(request),
      headers: [{"authorization", "Bearer " <> (config[:api_key] || "")}],
      receive_timeout: config[:receive_timeout] || @receive_timeout,
      retry: false,
      decode_body: false,
      into: &collect(&1, &2, on_event)
    ] ++ Map.get(config, :req_options, [])
  end

  # Req calls this with each chunk of the body: a stream is folded as it
  # arrives and its events reported at once; an error body is kept whole.
  defp collect({:data, data}, {req, %Req.Response{status: 200} = resp}, on_event) do
    {stream, events} = resp |> fold() |> Wire.feed(data)
    Enum.each(events, on_event)
    {:cont, {req, Req.Response.put_private(resp, :photon_relay, stream)}}
  end

  defp collect({:data, data}, {req, resp}, _on_event) do
    body = [Req.Response.get_private(resp, :photon_error_body, []), data]
    {:cont, {req, Req.Response.put_private(resp, :photon_error_body, body)}}
  end

  defp fold(resp), do: Req.Response.get_private(resp, :photon_relay, Wire.new())

  defp error_body(resp) do
    case IO.iodata_to_binary(Req.Response.get_private(resp, :photon_error_body, [])) do
      "" when is_binary(resp.body) -> resp.body
      body -> body
    end
  end

  # The hub's own refusals (a bad token, no model signed in) carry an error
  # it already decided on. Anything else came from in front of the hub (a
  # proxy while it restarts), and is worth a retry when it says so.
  defp refusal(status, body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => _} = error}} ->
        %{Wire.decode_error(error) | status: status}

      _other ->
        Error.new(:http, "the hub answered #{status}",
          status: status,
          retryable: status == 429 or status >= 500
        )
    end
  end
end
