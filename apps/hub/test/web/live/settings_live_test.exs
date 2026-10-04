defmodule PhotonWeb.SettingsLiveTest do
  @moduledoc "The settings page: the fields each provider needs, and the saved key."

  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :durable

  defp page(%{conn: conn}) do
    {:ok, view, _html} = live(conn, ~p"/settings")
    %{view: view}
  end

  setup :page

  test "asks for a base URL only for providers that need one", %{view: view} do
    refute has_element?(view, "#settings_base_url")

    view |> form("#settings-form", settings: %{provider: "ollama"}) |> render_change()
    assert has_element?(view, "#settings_base_url[placeholder='http://127.0.0.1:11434/v1']")
    refute has_element?(view, "#settings_api_key")
  end

  test "a saved key can be removed", %{view: view} do
    view |> form("#settings-form", settings: %{provider: "openai"}) |> render_change()

    view
    |> form("#settings-form", settings: %{provider: "openai", api_key: "sk-test"})
    |> render_submit()

    assert Photon.Settings.load()["api_key"] == "sk-test"
    assert has_element?(view, "button[phx-click=clear_key]")

    render_click(view, "clear_key")
    assert Photon.Settings.load()["api_key"] == ""
    assert has_element?(view, "#flash-info", "Removed the saved key.")
  end

  test "saves the name Blip calls you", %{view: view} do
    view |> form("#settings-form", settings: %{user_name: "  Henry  "}) |> render_submit()
    assert Photon.Settings.load()["user_name"] == "Henry"
    assert has_element?(view, "#settings_user_name[value=Henry]")
  end
end
