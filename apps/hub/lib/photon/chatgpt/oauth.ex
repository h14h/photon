defmodule Photon.ChatGPT.OAuth do
  @moduledoc """
  The rules of Sign in with ChatGPT, for an open-source app, as pure
  functions: the sign-in link, the address the browser lands on, the
  token requests, the tokens' claims, and when to refresh.

  How sign-in goes. The hub makes a link with a PKCE challenge, a `state`
  and a `nonce`, and keeps their secrets. The user approves Photon in
  ChatGPT, and the browser is sent to `http://127.0.0.1:<port>/auth/callback`,
  the only kind of address OpenAI allows an open-source app. That page
  doesn't load (the hub isn't the user's computer), so the user pastes its
  address into Photon, which checks `state` and trades the code for tokens.

  The first sign-in registers Photon with the user's account: it asks as
  `dynamic_agent_client`, and the address carries the client ID OpenAI
  issued, which every later request uses. Each hub has a host ID of its
  own, `urn:uuid:...`, chosen once and kept.

  The ID token comes straight from the token endpoint over TLS, so its
  claims are read and checked (issuer, audience, nonce, expiry) without
  verifying its signature, as OpenID Connect allows for that case.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [Jason]

  @issuer "https://auth.openai.com"
  @authorize_url @issuer <> "/api/accounts/authorize"
  @token_url @issuer <> "/api/accounts/oauth/token"
  @revoke_url @issuer <> "/api/accounts/oauth/revoke"
  @resource "https://api.openai.com/v1"
  @scope "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
  @plan_scope "chatgpt.tokens.use.direct"
  @dynamic_client "dynamic_agent_client"

  # Refresh a minute before expiry, and not before the server allows.
  @refresh_margin_ms 60_000

  # Token endpoint errors that mean the user has to sign in again.
  @sign_in_again ~w(invalid_grant invalid_refresh_token token_expired refresh_token_expired
                    refresh_token_invalidated refresh_token_reused)

  @typedoc """
  A sign-in under way: what the hub keeps until the user pastes the
  address: the PKCE verifier, `state`, `nonce`, the callback address and
  the client ID it asked as.
  """
  @type pending :: %{
          verifier: String.t(),
          state: String.t(),
          nonce: String.t(),
          redirect_uri: String.t(),
          client_id: String.t(),
          started_at: integer()
        }

  @typedoc "Tokens and who they belong to, as stored (string keys, so it round-trips as JSON)."
  @type credentials :: %{String.t() => term()}

  @spec token_url() :: String.t()
  def token_url, do: @token_url

  @spec revoke_url() :: String.t()
  def revoke_url, do: @revoke_url

  @spec resource() :: String.t()
  def resource, do: @resource

  @doc "A host ID from a random UUID."
  @spec host_id(String.t()) :: String.t()
  def host_id(uuid), do: "urn:uuid:" <> uuid

  @doc """
  A UUID v4 in its usual form, from 16 random bytes (the caller reads them).
  """
  @spec uuid(<<_::128>>) :: String.t()
  def uuid(<<a::48, _::4, b::12, _::2, c::62>>) do
    <<a::48, 4::4, b::12, 2::2, c::62>>
    |> Base.encode16(case: :lower)
    |> then(fn hex ->
      Enum.join(
        [
          binary_part(hex, 0, 8),
          binary_part(hex, 8, 4),
          binary_part(hex, 12, 4),
          binary_part(hex, 16, 4),
          binary_part(hex, 20, 12)
        ],
        "-"
      )
    end)
  end

  @doc """
  Starts a sign-in from three random secrets and a port (the caller makes
  them): returns what to keep and the link to open. `account` is what's
  known from an earlier sign-in: the issued `client_id`, and the old ID
  token and email as hints, all optional.
  """
  @spec begin(map(), map(), String.t(), integer()) :: {pending(), String.t()}
  def begin(secrets, account, host_id, now) do
    client_id = account["client_id"] || @dynamic_client
    redirect_uri = "http://127.0.0.1:#{secrets.port}/auth/callback"

    pending = %{
      verifier: secrets.verifier,
      state: secrets.state,
      nonce: secrets.nonce,
      redirect_uri: redirect_uri,
      client_id: client_id,
      started_at: now
    }

    params =
      [
        client_id: client_id,
        response_type: "code",
        redirect_uri: redirect_uri,
        scope: @scope,
        resource: @resource,
        state: secrets.state,
        nonce: secrets.nonce,
        code_challenge: challenge(secrets.verifier),
        code_challenge_method: "S256",
        ext_agent_host_id: host_id
      ] ++ hints(client_id, account)

    {pending, @authorize_url <> "?" <> URI.encode_query(params, :rfc3986)}
  end

  # A first sign-in suggests the app's name; a later one says who it was.
  defp hints(@dynamic_client, _account), do: [agent_name_hint: "Photon"]

  defp hints(_client_id, account) do
    Enum.reject(
      [id_token_hint: account["id_token"], login_hint: account["email"]],
      fn {_key, value} -> value in [nil, ""] end
    )
  end

  @doc "The PKCE challenge for a verifier (S256)."
  @spec challenge(String.t()) :: String.t()
  def challenge(verifier),
    do: :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

  @doc """
  Reads the address the browser landed on, pasted by the user: the code and
  the client ID to trade it with, or why not.
  """
  @spec read_callback(String.t(), pending()) ::
          {:ok, %{code: String.t(), client_id: String.t()}} | {:error, String.t()}
  def read_callback(pasted, pending) do
    params = pasted |> String.trim() |> query() |> URI.decode_query()

    cond do
      not Enum.any?(~w(code state error), &Map.has_key?(params, &1)) ->
        {:error,
         "That doesn't look like the address from the sign-in tab. Copy the whole address."}

      params["state"] != pending.state ->
        {:error, "That address is from a different sign-in. Start again and paste the new one."}

      params["error"] ->
        {:error, denial(params)}

      params["code"] in [nil, ""] ->
        {:error, "That address has no sign-in code. Copy the whole address."}

      true ->
        {:ok, %{code: params["code"], client_id: issued_client(params, pending)}}
    end
  end

  # The whole address, or only what follows its "?".
  defp query(text) do
    case URI.parse(text) do
      %URI{query: query} when is_binary(query) -> query
      _no_query -> text |> String.split("?", parts: 2) |> List.last()
    end
  end

  defp denial(%{"error" => "access_denied"}), do: "Sign-in was cancelled in ChatGPT."

  defp denial(params),
    do: "ChatGPT said no: #{params["error_description"] || params["error"]}."

  # A first sign-in's address names the client ID OpenAI issued; a later
  # one asked as that ID already.
  defp issued_client(%{"client_id" => client_id}, _pending)
       when is_binary(client_id) and client_id not in ["", @dynamic_client],
       do: client_id

  defp issued_client(_params, pending), do: pending.client_id

  @doc "The form that trades a code for tokens."
  @spec exchange_form(pending(), String.t(), String.t()) :: keyword()
  def exchange_form(pending, code, client_id) do
    [
      grant_type: "authorization_code",
      client_id: client_id,
      code: code,
      code_verifier: pending.verifier,
      redirect_uri: pending.redirect_uri,
      resource: @resource
    ]
  end

  @doc "The form that trades a refresh token for new tokens."
  @spec refresh_form(credentials()) :: keyword()
  def refresh_form(credentials) do
    [
      grant_type: "refresh_token",
      client_id: credentials["client_id"],
      refresh_token: credentials["refresh_token"],
      resource: @resource
    ]
  end

  @doc "The form that revokes a refresh token (signing out)."
  @spec revoke_form(credentials()) :: keyword()
  def revoke_form(credentials) do
    [
      token: credentials["refresh_token"],
      token_type_hint: "refresh_token",
      client_id: credentials["client_id"]
    ]
  end

  @doc """
  Credentials from a token response at `now` (Unix milliseconds). `expect`
  says what the ID token must show: the client ID, and the nonce on a
  first sign-in or the same subject on a refresh. A refresh that sends no
  new ID token or refresh token keeps the old ones (`previous`).
  """
  @spec credentials(map(), map(), credentials() | nil, integer()) ::
          {:ok, credentials()} | {:error, String.t()}
  def credentials(%{"access_token" => token} = response, expect, previous, now)
      when is_binary(token) do
    previous = previous || %{}
    id_token = response["id_token"] || previous["id_token"]

    with {:ok, claims} <- claims(id_token),
         :ok <- check_claims(claims, expect, now) do
      {:ok, stored(response, claims, Map.put(previous, "id_token", id_token), expect, now)}
    end
  end

  def credentials(_response, _expect, _previous, _now), do: {:error, "no access token"}

  defp stored(response, claims, previous, expect, now) do
    %{
      "client_id" => expect.client_id,
      "access_token" => response["access_token"],
      "refresh_token" => response["refresh_token"] || previous["refresh_token"],
      "id_token" => previous["id_token"],
      "scope" => response["scope"] || previous["scope"] || "",
      "expires_at" => now + seconds(response["expires_in"], 3600) * 1000,
      "earliest_refresh_at" => earliest_refresh(response["earliest_refresh_at"], now),
      "sub" => claims["sub"],
      "email" => claims["email"],
      "name" => claims["name"]
    }
  end

  defp seconds(n, _default) when is_integer(n) and n > 0, do: n
  defp seconds(_n, default), do: default

  # Unix seconds, or seconds from now when it's too small to be a date.
  defp earliest_refresh(at, _now) when is_integer(at) and at > 1_000_000_000, do: at * 1000
  defp earliest_refresh(at, now) when is_integer(at) and at > 0, do: now + at * 1000
  defp earliest_refresh(_at, _now), do: 0

  @doc "An ID token's claims, read without verifying its signature (see the moduledoc)."
  @spec claims(term()) :: {:ok, map()} | {:error, String.t()}
  def claims(token) when is_binary(token) do
    with [_header, payload, _signature] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{} = claims} <- Jason.decode(json) do
      {:ok, claims}
    else
      _ -> {:error, "the ID token couldn't be read"}
    end
  end

  def claims(_token), do: {:error, "no ID token"}

  # Each check is a failure's message, or nil when the claims pass it.
  defp check_claims(claims, expect, now) do
    [
      issuer_check(claims),
      audience_check(claims, expect),
      nonce_check(claims, expect, now),
      subject_check(claims, expect)
    ]
    |> Enum.find(&is_binary/1)
    |> then(&if(&1, do: {:error, &1}, else: :ok))
  end

  defp issuer_check(claims) do
    if String.trim_trailing(claims["iss"] || "", "/") != @issuer,
      do: "the ID token is from someone else"
  end

  defp audience_check(claims, expect) do
    if expect.client_id not in List.wrap(claims["aud"]), do: "the ID token is for another app"
  end

  # A first sign-in's ID token answers its nonce, and is fresh.
  defp nonce_check(claims, %{nonce: nonce}, now) do
    cond do
      claims["nonce"] != nonce -> "the ID token doesn't match this sign-in"
      not (is_integer(claims["exp"]) and claims["exp"] * 1000 > now) -> "the ID token has expired"
      true -> nil
    end
  end

  defp nonce_check(_claims, _expect, _now), do: nil

  # A refresh's tokens are for the same account.
  defp subject_check(claims, %{sub: sub}) do
    if claims["sub"] != sub, do: "the refreshed tokens are for a different account"
  end

  defp subject_check(_claims, _expect), do: nil

  @doc "Whether the tokens may use the user's plan (the user allowed it at sign-in)."
  @spec plan_use?(credentials()) :: boolean()
  def plan_use?(credentials),
    do: @plan_scope in String.split(credentials["scope"] || "", " ", trim: true)

  @doc "Whether the access token should be refreshed at `now` before it's used."
  @spec refresh_due?(credentials(), integer()) :: boolean()
  def refresh_due?(credentials, now) do
    expires_at = credentials["expires_at"] || 0

    now >= expires_at or
      (now >= expires_at - @refresh_margin_ms and now >= (credentials["earliest_refresh_at"] || 0))
  end

  @doc """
  What a failed token request means: `:sign_in_again` when the refresh
  token is no good, else `:retry_later`. `body` is the token endpoint's
  JSON error, when it sent one.
  """
  @spec failure(term()) :: :sign_in_again | :retry_later
  def failure(%{"error" => code}) when code in @sign_in_again, do: :sign_in_again
  def failure(_body), do: :retry_later

  @doc """
  The models an account can use, from `GET /v1/models`: `[%{id, name}]` in
  the server's order, listed ones only. Reads both the ChatGPT shape
  (`"models"` with `"slug"`) and the API shape (`"data"` with `"id"`).
  """
  @spec models(term()) :: [%{id: String.t(), name: String.t()}]
  def models(%{"models" => models}) when is_list(models) do
    for %{"slug" => slug} = model <- models,
        is_binary(slug),
        model["visibility"] in [nil, "list"],
        do: %{id: slug, name: model["display_name"] || slug}
  end

  def models(%{"data" => models}) when is_list(models) do
    for %{"id" => id} <- models, is_binary(id), do: %{id: id, name: id}
  end

  def models(_body), do: []
end
