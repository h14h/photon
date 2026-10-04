defmodule PhotonCore.StubProvider do
  @moduledoc """
  `Req.Test` stubs that play a Chat Completions provider, for boundary
  tests. The stub runs in the process that makes the request, so each test
  gets its own; every request it sees is also sent to the test process as
  `{:provider_request, %{body: decoded_json, headers: headers}}`.
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  import Plug.Conn

  @doc "Answers every request with `body`, the whole SSE body, at once."
  def streams(stub, body), do: streams_in_pieces(stub, [body])

  @doc "Answers every request with the SSE body sent in `pieces`, one HTTP chunk each."
  def streams_in_pieces(stub, pieces) do
    reply(stub, fn conn ->
      conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

      Enum.reduce(pieces, conn, fn piece, conn ->
        {:ok, conn} = chunk(conn, piece)
        conn
      end)
    end)
  end

  @doc """
  Answers the requests in turn with `responses`, repeating the last one:
  each is `{status, body}`, `{status, body, headers}`, `{:stream, body}` or
  `:drop` (a transport error).
  """
  def answers(stub, responses) do
    counter = :counters.new(1, [])

    reply(stub, fn conn ->
      :counters.add(counter, 1, 1)
      response = Enum.at(responses, :counters.get(counter, 1) - 1, List.last(responses))
      answer(conn, response)
    end)
  end

  defp answer(conn, :drop), do: Req.Test.transport_error(conn, :econnrefused)

  defp answer(conn, {:stream, body}),
    do: conn |> put_resp_content_type("text/event-stream") |> send_resp(200, body)

  defp answer(conn, {status, body}), do: send_resp(conn, status, body)

  defp answer(conn, {status, body, headers}) do
    headers
    |> Enum.reduce(conn, fn {name, value}, conn -> put_resp_header(conn, name, value) end)
    |> send_resp(status, body)
  end

  defp reply(stub, respond) do
    test_process = self()

    Req.Test.stub(stub, fn conn ->
      {:ok, body, conn} = read_body(conn)

      send(
        test_process,
        {:provider_request, %{body: Jason.decode!(body), headers: conn.req_headers}}
      )

      respond.(conn)
    end)
  end
end
