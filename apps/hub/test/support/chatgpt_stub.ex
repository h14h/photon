defmodule Photon.ChatGPTStub do
  @moduledoc """
  Plays OpenAI's side of Sign in with ChatGPT for tests: the token, revoke
  and models endpoints, through a `Req.Test` stub the `Photon.ChatGPT`
  process uses. Every request it sees is also sent to the test process as
  `{:openai_request, path, params}`.

  `reset!/0` gives each test a hub that has never signed in; `sign_in!/1`
  goes through the whole sign-in the way a user does.
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  import ExUnit.Assertions
  import Plug.Conn

  alias Photon.{ChatGPT, Paths}

  @doc "Forgets the account and restarts the process, so the hub has never signed in."
  def reset! do
    _removed = File.rm_rf!(Paths.chatgpt_file())
    :ok = Supervisor.terminate_child(Photon.Supervisor, ChatGPT)
    {:ok, _pid} = Supervisor.restart_child(Photon.Supervisor, ChatGPT)
    :ok
  end

  @doc """
  Answers OpenAI's endpoints with `answers`: a map from path to a function
  of the request's params returning `{status, json}`. Paths not listed get
  404.
  """
  def answer(answers) do
    test = self()

    Req.Test.stub(ChatGPT, fn conn ->
      conn = conn |> fetch_query_params()
      {:ok, body, conn} = read_body(conn)
      params = Map.merge(conn.query_params, URI.decode_query(body))
      send(test, {:openai_request, conn.request_path, params})

      reply(conn, answers[conn.request_path], params)
    end)

    Req.Test.allow(ChatGPT, self(), Process.whereis(ChatGPT))
    :ok
  end

  defp reply(conn, nil, _params), do: send_json(conn, 404, %{"error" => "not_found"})

  defp reply(conn, answer, params) do
    {status, json} = answer.(params)
    send_json(conn, status, json)
  end

  defp send_json(conn, status, json),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(json))

  @doc "A token response for `client_id`, whose ID token carries `claims` (a nonce, say)."
  def tokens(client_id, claims, fields \\ %{}) do
    Map.merge(
      %{
        "access_token" => "at_" <> Integer.to_string(System.unique_integer([:positive])),
        "refresh_token" => "rt_" <> Integer.to_string(System.unique_integer([:positive])),
        "id_token" => id_token(client_id, claims),
        "expires_in" => 3600,
        "scope" => "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
      },
      fields
    )
  end

  @doc "An ID token (unsigned: the hub reads its claims, see `Photon.ChatGPT.OAuth`)."
  def id_token(client_id, claims) do
    claims =
      Map.merge(
        %{
          "iss" => "https://auth.openai.com",
          "aud" => client_id,
          "sub" => "user_1",
          "email" => "henry@example.com",
          "name" => "Henry",
          "exp" => System.system_time(:second) + 3600
        },
        claims
      )

    payload = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
    "eyJhbGciOiJSUzI1NiJ9." <> payload <> ".sig"
  end

  @doc """
  Signs in as a user does: starts, approves (the stub issues `oaiapp_1`),
  and pastes the address. `fields` go into the token response.
  """
  def sign_in!(fields \\ %{}) do
    {:ok, url} = ChatGPT.begin_sign_in()
    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    answer(%{
      "/api/accounts/oauth/token" => fn _params ->
        {200, tokens("oaiapp_1", %{"nonce" => query["nonce"]}, fields)}
      end
    })

    address =
      query["redirect_uri"] <>
        "?" <> URI.encode_query(code: "code_1", state: query["state"], client_id: "oaiapp_1")

    assert :ok = ChatGPT.finish_sign_in(address)
    query
  end
end
