defmodule PhotonWeb.ContextFileLiveTest do
  @moduledoc "A project's context file: making one and editing one."

  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Photon.Projects

  @moduletag :durable

  setup do
    {:ok, project} =
      Projects.create(%{"purpose" => "Keep the garden watered.", "name" => "Garden"})

    {:ok, _notes} =
      Projects.create_file(project.id, %{"name" => "notes", "content" => "Zone 2."})

    %{project: project}
  end

  test "the new-file page mounts", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/files/new")
    assert view |> element("#file-heading") |> render() =~ "New file"
    assert has_element?(view, ~s(#file-project[href="/projects/garden"]))
  end

  test "a file's page finds it by name, in any case", %{conn: conn, project: project} do
    for name <- ["notes.md", "Notes.md"] do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/files/#{name}")
      assert view |> element("#file-heading") |> render() =~ "notes.md"
    end
  end

  test "an unknown project or file goes home with a flash", %{conn: conn, project: project} do
    for {path, message} <- [
          {~p"/projects/orchard/files/new", "There's no project called orchard."},
          {~p"/projects/orchard/files/notes.md", "There's no project called orchard."},
          {~p"/projects/#{project.slug}/files/plan.md",
           "There's no file called plan.md in Garden."}
        ] do
      assert {:error, {:live_redirect, %{to: "/", flash: flash}}} = live(conn, path)
      assert flash["error"] == message
    end
  end
end
