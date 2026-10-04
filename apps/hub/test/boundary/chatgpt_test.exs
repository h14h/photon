defmodule Photon.ChatGPTTest do
  @moduledoc """
  The ChatGPT account (`Photon.ChatGPT`) as the settings page and the model
  requests use it, against a stub of OpenAI's endpoints: signing in,
  refreshing, lapsing and signing out.
  """

  use Photon.DataCase, async: false

  alias Photon.{ChatGPT, ChatGPTStub, Paths}

  setup do
    ChatGPTStub.reset!()
    ChatGPT.subscribe()
    :ok
  end

  test "a hub that never signed in is signed out, with a host ID kept for good" do
    assert %{state: :signed_out, signing_in: false} = ChatGPT.status()
    assert {:error, "Not signed in with ChatGPT."} = ChatGPT.access_token()

    host_id = Jason.decode!(File.read!(Paths.chatgpt_file()))["host_id"]
    assert "urn:uuid:" <> _ = host_id

    {:ok, url} = ChatGPT.begin_sign_in()
    assert url =~ URI.encode_www_form(host_id)
  end

  test "signing in trades the code for tokens and keeps them, readable by the hub only" do
    query = ChatGPTStub.sign_in!()

    assert_received {:openai_request, "/api/accounts/oauth/token", form}

    assert %{
             "grant_type" => "authorization_code",
             "client_id" => "oaiapp_1",
             "code" => "code_1",
             "redirect_uri" => redirect,
             "resource" => "https://api.openai.com/v1"
           } = form

    assert redirect == query["redirect_uri"]
    assert_received {:chatgpt_changed, %{state: :signed_in, email: "henry@example.com"}}
    assert %{state: :signed_in, plan_use: true, signing_in: false} = ChatGPT.status()
    assert {:ok, "at_" <> _} = ChatGPT.access_token()

    assert File.stat!(Paths.chatgpt_file()).mode |> Bitwise.band(0o777) == 0o600
    assert Jason.decode!(File.read!(Paths.chatgpt_file()))["client_id"] == "oaiapp_1"
  end

  test "signing in again asks as the client OpenAI issued, with the old tokens as hints" do
    ChatGPTStub.sign_in!()
    :ok = ChatGPT.sign_out()

    {:ok, url} = ChatGPT.begin_sign_in()
    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert %{"client_id" => "oaiapp_1", "login_hint" => "henry@example.com"} = query
    assert query["id_token_hint"]
  end

  test "a code ChatGPT won't trade leaves the issued client ID kept, so it isn't registered twice" do
    {:ok, url} = ChatGPT.begin_sign_in()
    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    ChatGPTStub.answer(%{
      "/api/accounts/oauth/token" => fn _ -> {400, %{"error" => "invalid_grant"}} end
    })

    address = "?" <> URI.encode_query(code: "c", state: query["state"], client_id: "oaiapp_7")

    assert {:error, "ChatGPT didn't accept the sign-in: invalid_grant"} =
             ChatGPT.finish_sign_in(address)

    {:ok, url} = ChatGPT.begin_sign_in()
    assert URI.decode_query(URI.parse(url).query)["client_id"] == "oaiapp_7"
  end

  test "pasting the wrong address keeps the sign-in waiting" do
    {:ok, _url} = ChatGPT.begin_sign_in()

    assert {:error, "That address is from a different sign-in." <> _} =
             ChatGPT.finish_sign_in("?code=c&state=nope")

    assert %{state: :signed_out, signing_in: true} = ChatGPT.status()
    assert :ok = ChatGPT.cancel_sign_in()
    assert %{signing_in: false} = ChatGPT.status()
  end

  test "an access token about to expire is refreshed first, once" do
    ChatGPTStub.sign_in!(%{"expires_in" => 30})
    {:ok, old} = ChatGPT.access_token()

    ChatGPTStub.answer(%{
      "/api/accounts/oauth/token" => fn %{"grant_type" => "refresh_token"} ->
        {200, %{"access_token" => "at_fresh", "expires_in" => 3600}}
      end
    })

    flush_requests()
    {:ok, fresh} = ChatGPT.access_token()
    assert fresh == "at_fresh" and fresh != old
    assert_received {:openai_request, "/api/accounts/oauth/token", %{"client_id" => "oaiapp_1"}}

    assert {:ok, "at_fresh"} = ChatGPT.access_token()
    refute_received {:openai_request, _, _}
  end

  test "a token the API refused is refreshed before it's handed out again" do
    ChatGPTStub.sign_in!()
    {:ok, token} = ChatGPT.access_token()

    ChatGPTStub.answer(%{
      "/api/accounts/oauth/token" => fn _ -> {200, %{"access_token" => "at_after_401"}} end
    })

    :ok = ChatGPT.token_rejected("someone else's")
    assert {:ok, ^token} = ChatGPT.access_token()

    :ok = ChatGPT.token_rejected(token)
    assert {:ok, "at_after_401"} = ChatGPT.access_token()
  end

  @tag capture_log: true
  test "a refresh token that's no good lapses the sign-in" do
    ChatGPTStub.sign_in!(%{"expires_in" => 1})

    ChatGPTStub.answer(%{
      "/api/accounts/oauth/token" => fn _ -> {400, %{"error" => "refresh_token_expired"}} end
    })

    assert {:error, "The ChatGPT sign-in lapsed." <> _} = ChatGPT.access_token()
    assert_received {:chatgpt_changed, %{state: :sign_in_again}}
    assert %{state: :sign_in_again} = ChatGPT.status()
  end

  test "a refresh that fails for a moment keeps the sign-in" do
    ChatGPTStub.sign_in!(%{"expires_in" => 1})

    ChatGPTStub.answer(%{
      "/api/accounts/oauth/token" => fn _ -> {503, %{"error" => "temporarily_unavailable"}} end
    })

    assert {:error, "Couldn't refresh the ChatGPT sign-in" <> _} = ChatGPT.access_token()
    assert %{state: :signed_in} = ChatGPT.status()
  end

  test "signing out revokes the refresh token and forgets the tokens" do
    ChatGPTStub.sign_in!()

    ChatGPTStub.answer(%{"/api/accounts/oauth/revoke" => fn _ -> {200, %{}} end})
    assert :ok = ChatGPT.sign_out()

    assert_received {:openai_request, "/api/accounts/oauth/revoke", %{"token" => "rt_" <> _}}
    assert %{state: :signed_out} = ChatGPT.status()
    assert Jason.decode!(File.read!(Paths.chatgpt_file()))["credentials"] == nil
  end

  test "the account's models are listed, and kept a few minutes" do
    ChatGPTStub.sign_in!()

    ChatGPTStub.answer(%{
      "/v1/models" => fn _ ->
        {200, %{"models" => [%{"slug" => "gpt-6.1-sol", "display_name" => "GPT-6.1 Sol"}]}}
      end
    })

    assert {:ok, [%{id: "gpt-6.1-sol", name: "GPT-6.1 Sol"}]} = ChatGPT.models()
    assert {:ok, [_]} = ChatGPT.models()
    assert [_] = for({:openai_request, "/v1/models", _} <- flush_requests(), do: 1)
  end

  test "without the scripted model, a request gets the token, or none when signed out" do
    Application.put_env(:photon, :mock_model, false)
    on_exit(fn -> Application.put_env(:photon, :mock_model, true) end)

    assert %{provider: "chatgpt", api_key: nil} = ChatGPT.llm_config(nil)
    refute ChatGPT.ready?(ChatGPT.status())

    ChatGPTStub.sign_in!()
    assert %{provider: "chatgpt", api_key: "at_" <> _} = ChatGPT.llm_config(nil)
    assert ChatGPT.ready?(ChatGPT.status())
  end

  defp flush_requests(acc \\ []) do
    receive do
      {:openai_request, _, _} = request -> flush_requests([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
