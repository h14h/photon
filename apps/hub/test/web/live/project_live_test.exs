defmodule PhotonWeb.ProjectLiveTest do
  @moduledoc "A project's page, at `/projects/:slug`."

  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Photon.Projects

  @moduletag :durable

  setup do
    {:ok, project} =
      Projects.create(%{"purpose" => "Keep the garden watered.", "name" => "Garden"})

    %{project: project}
  end

  test "shows the project by its slug", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")
    assert view |> element("#project-name") |> render() =~ "Garden"
    assert view |> element("#project-folder") |> render() =~ "garden"
  end

  test "an unknown slug goes home with a flash", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/", flash: flash}}} =
             live(conn, ~p"/projects/orchard")

    assert flash["error"] == "There's no project called orchard."
  end
end
