defmodule PhotonWeb.ProjectNewLiveTest do
  @moduledoc "Starting a project, at `/projects/new`."

  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Photon.Projects

  @moduletag :durable

  test "mounts at /projects/new, ahead of the project route", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/projects/new")
    assert has_element?(view, "#project-new-heading")
    assert has_element?(view, "#project-form #project-purpose-input")
    assert has_element?(view, "#project-form #project-name-input")
    refute has_element?(view, "#project-name")
  end

  test "a blank purpose shows the error under the form, and makes nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/projects/new")

    html =
      view
      |> form("#project-form", project: %{purpose: "  ", name: "Garden"})
      |> render_submit()

    assert html =~ "Say what the project is for."
    assert has_element?(view, "#project-form", "Say what the project is for.")
    assert has_element?(view, ~s(#project-name-input[value="Garden"]))
    assert Projects.list() == []
  end

  test "a purpose alone starts the project and opens its page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/projects/new")

    assert {:error, {:live_redirect, %{to: "/projects/keep-the-garden-watered"}}} =
             view
             |> form("#project-form",
               project: %{purpose: "Keep the garden watered. Three zones."}
             )
             |> render_submit()

    assert [%{name: "Keep the garden watered", slug: "keep-the-garden-watered"}] =
             Projects.list()
  end

  test "a name sets the slug, and the new page follows", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/projects/new")

    {:ok, project_view, _html} =
      view
      |> form("#project-form", project: %{purpose: "Plan the trip.", name: "Trip"})
      |> render_submit()
      |> follow_redirect(conn, ~p"/projects/trip")

    assert project_view |> element("#project-name") |> render() =~ "Trip"
  end
end
