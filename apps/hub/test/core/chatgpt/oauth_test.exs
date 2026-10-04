defmodule Photon.ChatGPT.OAuthTest do
  @moduledoc "The rules of Sign in with ChatGPT, as pure functions."

  use Photon.Case, async: true

  alias Photon.ChatGPT.OAuth
  alias Photon.ChatGPTStub

  @secrets %{verifier: "verifier", state: "state_1", nonce: "nonce_1", port: 50_123}
  @now 1_791_000_000_000

  defp begin(account \\ %{}), do: OAuth.begin(@secrets, account, "urn:uuid:host", @now)
  defp query(url), do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

  describe "the sign-in link" do
    test "a first sign-in registers Photon, with the host ID and a loopback callback" do
      {pending, url} = begin()
      query = query(url)

      assert String.starts_with?(url, "https://auth.openai.com/api/accounts/authorize?")

      assert %{
               "client_id" => "dynamic_agent_client",
               "agent_name_hint" => "Photon",
               "ext_agent_host_id" => "urn:uuid:host",
               "redirect_uri" => "http://127.0.0.1:50123/auth/callback",
               "resource" => "https://api.openai.com/v1",
               "state" => "state_1",
               "nonce" => "nonce_1",
               "code_challenge_method" => "S256",
               "response_type" => "code"
             } = query

      assert query["scope"] =~ "chatgpt.tokens.use.direct"
      assert query["code_challenge"] == OAuth.challenge("verifier")
      assert pending.redirect_uri == query["redirect_uri"]
    end

    test "a later sign-in asks as the issued client, with the old tokens as hints" do
      {pending, url} = begin(%{"client_id" => "oaiapp_1", "id_token" => "old", "email" => "h@x"})
      query = query(url)

      assert %{"client_id" => "oaiapp_1", "id_token_hint" => "old", "login_hint" => "h@x"} = query
      refute Map.has_key?(query, "agent_name_hint")
      assert pending.client_id == "oaiapp_1"
    end

    test "the PKCE challenge is the verifier's SHA-256, base64url without padding" do
      # RFC 7636, appendix B.
      assert OAuth.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") ==
               "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    end

    test "host IDs are random UUIDs of version 4" do
      uuid = OAuth.uuid(<<0::128>>)
      assert uuid == "00000000-0000-4000-8000-000000000000"
      assert OAuth.host_id(uuid) == "urn:uuid:" <> uuid
    end
  end

  describe "the pasted address" do
    setup do
      {pending, _url} = begin()
      %{pending: pending}
    end

    test "gives the code and the client ID OpenAI issued", %{pending: pending} do
      pasted = " http://127.0.0.1:50123/auth/callback?code=c1&state=state_1&client_id=oaiapp_9 "
      assert OAuth.read_callback(pasted, pending) == {:ok, %{code: "c1", client_id: "oaiapp_9"}}
    end

    test "a later sign-in keeps the client ID it asked as", %{pending: pending} do
      pending = %{pending | client_id: "oaiapp_1"}

      assert {:ok, %{client_id: "oaiapp_1"}} =
               OAuth.read_callback("?code=c1&state=state_1", pending)
    end

    test "refuses another sign-in's address, a cancel, and anything else", %{pending: pending} do
      assert {:error, "That address is from a different sign-in." <> _} =
               OAuth.read_callback("http://127.0.0.1:1/auth/callback?code=c&state=other", pending)

      assert {:error, "Sign-in was cancelled in ChatGPT."} =
               OAuth.read_callback("?error=access_denied&state=state_1", pending)

      assert {:error, "That address has no sign-in code." <> _} =
               OAuth.read_callback("?state=state_1", pending)

      assert {:error, "That doesn't look like" <> _} = OAuth.read_callback("hello", pending)
    end
  end

  describe "the tokens" do
    test "are read with who they're for, and when to refresh" do
      response =
        ChatGPTStub.tokens("oaiapp_1", %{"nonce" => "n"}, %{"earliest_refresh_at" => 600})

      assert {:ok, credentials} =
               OAuth.credentials(response, %{client_id: "oaiapp_1", nonce: "n"}, nil, @now)

      assert %{
               "client_id" => "oaiapp_1",
               "email" => "henry@example.com",
               "sub" => "user_1",
               "expires_at" => expires_at,
               "earliest_refresh_at" => earliest
             } = credentials

      assert expires_at == @now + 3_600_000
      assert earliest == @now + 600_000
      assert OAuth.plan_use?(credentials)

      refute OAuth.refresh_due?(credentials, @now)
      refute OAuth.refresh_due?(credentials, expires_at - 120_000)
      assert OAuth.refresh_due?(credentials, expires_at - 30_000)
      assert OAuth.refresh_due?(%{credentials | "earliest_refresh_at" => @now * 2}, expires_at)
    end

    test "an ID token for another app, sign-in or account is refused" do
      response = ChatGPTStub.tokens("oaiapp_1", %{"nonce" => "n"})

      assert {:error, "the ID token is for another app"} =
               OAuth.credentials(response, %{client_id: "oaiapp_2", nonce: "n"}, nil, @now)

      assert {:error, "the ID token doesn't match this sign-in"} =
               OAuth.credentials(response, %{client_id: "oaiapp_1", nonce: "x"}, nil, @now)

      assert {:error, "the refreshed tokens are for a different account"} =
               OAuth.credentials(response, %{client_id: "oaiapp_1", sub: "user_2"}, nil, @now)

      bad_issuer = ChatGPTStub.tokens("oaiapp_1", %{"iss" => "https://evil"})

      assert {:error, "the ID token is from someone else"} =
               OAuth.credentials(bad_issuer, %{client_id: "oaiapp_1"}, nil, @now)
    end

    test "a refresh without a new refresh or ID token keeps the old ones" do
      first = ChatGPTStub.tokens("oaiapp_1", %{})

      {:ok, old} = OAuth.credentials(first, %{client_id: "oaiapp_1"}, nil, @now)

      {:ok, renewed} =
        OAuth.credentials(%{"access_token" => "at_new"}, %{client_id: "oaiapp_1"}, old, @now)

      assert renewed["access_token"] == "at_new"
      assert renewed["refresh_token"] == old["refresh_token"]
      assert renewed["id_token"] == old["id_token"]
    end

    test "without plan use allowed, the tokens can't think" do
      response = ChatGPTStub.tokens("oaiapp_1", %{}, %{"scope" => "openid email"})
      {:ok, credentials} = OAuth.credentials(response, %{client_id: "oaiapp_1"}, nil, @now)
      refute OAuth.plan_use?(credentials)
    end

    test "a refresh token that's no good means signing in again; anything else, later" do
      for code <- ~w(invalid_grant refresh_token_expired refresh_token_reused),
          do: assert(OAuth.failure(%{"error" => code}) == :sign_in_again)

      assert OAuth.failure(%{"error" => "temporarily_unavailable"}) == :retry_later
      assert OAuth.failure("<html>") == :retry_later
    end
  end

  test "the forms carry the issued client ID and the resource" do
    {pending, _url} = begin()

    assert OAuth.exchange_form(pending, "c1", "oaiapp_1") == [
             grant_type: "authorization_code",
             client_id: "oaiapp_1",
             code: "c1",
             code_verifier: "verifier",
             redirect_uri: "http://127.0.0.1:50123/auth/callback",
             resource: "https://api.openai.com/v1"
           ]

    credentials = %{"client_id" => "oaiapp_1", "refresh_token" => "rt"}
    assert OAuth.refresh_form(credentials)[:grant_type] == "refresh_token"
    assert OAuth.revoke_form(credentials)[:token_type_hint] == "refresh_token"
  end

  test "models come in the server's order, listed ones only, in either shape" do
    chatgpt = %{
      "models" => [
        %{"slug" => "gpt-6.1-sol", "display_name" => "GPT-6.1 Sol", "visibility" => "list"},
        %{"slug" => "hidden", "visibility" => "hide"},
        %{"slug" => "gpt-6-luna"}
      ]
    }

    assert OAuth.models(chatgpt) == [
             %{id: "gpt-6.1-sol", name: "GPT-6.1 Sol"},
             %{id: "gpt-6-luna", name: "gpt-6-luna"}
           ]

    assert OAuth.models(%{"data" => [%{"id" => "m"}]}) == [%{id: "m", name: "m"}]
    assert OAuth.models(nil) == []
  end
end
