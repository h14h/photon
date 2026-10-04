defmodule PhotonWeb.SettingsLiveTest do
  @moduledoc """
  The settings page: signing in with ChatGPT (against a stub of OpenAI's
  endpoints), the model choices once signed in, what Blip knows about the
  user, and what Blip remembers.
  """

  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Photon.{ChatGPT, ChatGPTStub}

  @moduletag :durable

  setup %{conn: conn} do
    ChatGPTStub.reset!()
    {:ok, view, _html} = live(conn, ~p"/settings")
    %{view: view}
  end

  defp query(url), do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

  describe "signed out" do
    test "offers Sign in with ChatGPT and nothing about models", %{view: view} do
      assert has_element?(view, "#begin-sign-in")
      refute has_element?(view, "#settings_model")
      assert has_element?(view, "#sign-in-banner")
    end

    test "signing in is: open ChatGPT, then paste the address you land on", %{view: view} do
      view |> element("#begin-sign-in") |> render_click()
      assert has_element?(view, "#sign-in-steps")

      href = view |> element("#open-sign-in") |> render() |> LazyHTML.from_fragment()
      [url] = LazyHTML.attribute(href, "href")
      assert String.starts_with?(url, "https://auth.openai.com/api/accounts/authorize?")
      query = query(url)

      view
      |> form("#finish-sign-in", sign_in: %{address: "?code=c&state=wrong"})
      |> render_submit()

      assert has_element?(view, "#sign-in-error", "different sign-in")

      ChatGPTStub.answer(%{
        "/api/accounts/oauth/token" => fn _ ->
          {200, ChatGPTStub.tokens("oaiapp_1", %{"nonce" => query["nonce"]})}
        end,
        "/v1/models" => fn _ ->
          {200, %{"models" => [%{"slug" => "gpt-6-luna", "display_name" => "GPT-6 Luna"}]}}
        end
      })

      address =
        query["redirect_uri"] <>
          "?" <> URI.encode_query(code: "c1", state: query["state"], client_id: "oaiapp_1")

      view |> form("#finish-sign-in", sign_in: %{address: address}) |> render_submit()

      assert has_element?(view, "#flash-info", "Signed in with ChatGPT")
      assert has_element?(view, "#chatgpt-account", "henry@example.com")
      refute has_element?(view, "#sign-in-banner")
      assert has_element?(view, "#settings_model option[value=gpt-6-luna]", "GPT-6 Luna")
    end

    test "a sign-in can be cancelled", %{view: view} do
      view |> element("#begin-sign-in") |> render_click()
      render_click(view, "cancel_sign_in")
      refute has_element?(view, "#sign-in-steps")
      assert %{signing_in: false} = ChatGPT.status()
    end
  end

  describe "signed in" do
    setup %{view: view} do
      ChatGPTStub.sign_in!()
      _ = render(view)
      :ok
    end

    test "picks a model and an effort, and asks before scheduled work", %{view: view} do
      view
      |> form("#settings-form",
        settings: %{model: "gpt-6.1-sol", reasoning: "high", scheduled_work: "true"}
      )
      |> render_submit()

      settings = Photon.Settings.load()
      assert %{"model" => "gpt-6.1-sol", "reasoning" => "high"} = settings
      assert Photon.Settings.scheduled_work?(settings)
    end

    test "signing out stops Blip until the next sign-in", %{view: view} do
      ChatGPTStub.answer(%{"/api/accounts/oauth/revoke" => fn _ -> {200, %{}} end})
      view |> element("#sign-out") |> render_click()

      assert has_element?(view, "#begin-sign-in")
      assert has_element?(view, "#sign-in-banner")
    end
  end

  test "saves the name Blip calls you", %{view: view} do
    view |> form("#settings-form", settings: %{user_name: "  Henry  "}) |> render_submit()
    assert Photon.Settings.load()["user_name"] == "Henry"
    assert has_element?(view, "#settings_user_name[value=Henry]")
  end

  describe "what Blip remembers" do
    test "can be edited, or the edit cancelled", %{view: view} do
      view |> element("#edit-memory") |> render_click()
      assert has_element?(view, "#memory-form")
      render_click(view, "cancel_memory")
      refute has_element?(view, "#memory-form")

      view |> element("#edit-memory") |> render_click()
      view |> form("#memory-form", memory: "  likes tea  ") |> render_submit()
      assert Photon.Assistant.memory() == "likes tea"
      assert has_element?(view, "#memory-text", "likes tea")
    end

    test "shows what Blip saves", %{view: view} do
      assert has_element?(view, "#memory-text", "Empty")
      Photon.Assistant.put_memory("the NAS is mp1")
      assert has_element?(view, "#memory-text", "the NAS is mp1")
    end

    test "a fresh context keeps the history and marks the break", %{view: view} do
      conversation = Photon.Assistant.conversation_id()
      Photon.Durable.subscribe(conversation)

      view |> element("#fresh-start") |> render_click()
      await_entry(conversation, &(&1.kind == "reset"))
      assert has_element?(view, "#flash-info", "fresh context")
    end
  end
end
