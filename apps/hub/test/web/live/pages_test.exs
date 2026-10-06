defmodule PhotonWeb.PagesTest do
  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :durable

  alias Photon.{Durable, Machines, NodeKeys}

  test "the overview shows machines and schedules", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#no-machines")
    assert has_element?(view, "#schedules")
    assert has_element?(view, "#nav-home")
  end

  test "Blip answers in the conversation over the page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    blip = find_live_child(view, "blip")
    assert has_element?(blip, "#composer")
    assert has_element?(blip, "#empty-state")

    conversation = Photon.Assistant.conversation_id()
    Durable.subscribe(conversation)

    blip |> form("#composer", message: %{text: "help"}) |> render_submit()
    await_entry(conversation, &(&1.kind == "assistant"))

    _ = render(blip)
    assert has_element?(blip, "#entries [id^=entries-]")
    refute has_element?(blip, "#empty-state")
  end

  test "the nodes page offers both ways to add a node", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/nodes")
    assert has_element?(view, "#add-node")
    assert has_element?(view, "#manual-key-form")
  end

  test "settings save", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#settings-form", settings: %{timezone: "America/Chicago", user_name: "Henry"})
    |> render_submit()

    settings = Photon.Settings.load()
    assert settings["timezone"] == "America/Chicago"
    assert settings["user_name"] == "Henry"
  end

  test "no page links to node sessions, which are gone", %{conn: conn} do
    {:ok, _key} = NodeKeys.issue("nas")
    :ok = Machines.register("box", %{"hostname" => "box.lan", "platform" => "linux"})

    for path <- [~p"/", ~p"/nodes", ~p"/settings"] do
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, "#nav-machines[href='/nodes']", "1 online")
      refute has_element?(view, ~s(a[href^="/sessions"]))
      refute has_element?(find_live_child(view, "blip"), ~s(a[href^="/sessions"]))
    end

    assert get(conn, "/sessions/ns_1").status == 404
  end
end
