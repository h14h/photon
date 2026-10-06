defmodule PhotonWeb.ProjectNewLiveTest do
  @moduledoc "Starting a project, at `/projects/new`."

  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :durable

  test "mounts at /projects/new, ahead of the project route", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/projects/new")
    assert has_element?(view, "#project-new-heading")
    refute has_element?(view, "#project-name")
  end
end
