defmodule PhotonWeb.ContextFileLiveTest do
  @moduledoc """
  A project's context file: making one, editing one, and what the editor
  does when a thread or Blip writes or deletes the open file.

  A thread's or Blip's write is committed through `Projects.write_file_tx/5`,
  as the context-file tools do it. The Store broadcasts inside the commit's call,
  so the page has the announcement queued before the test's next render.
  """

  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Photon.{Durable, Projects, Threads}

  @moduletag :durable

  setup do
    {:ok, project} =
      Projects.create(%{"purpose" => "Keep the garden watered.", "name" => "Garden"})

    {:ok, notes} =
      Projects.create_file(project.id, %{"name" => "notes", "content" => "Zone 2."})

    %{project: project, notes: notes}
  end

  # Writes `content` over notes.md as `writer` (a thread's ID or "blip") would.
  defp thread_writes(project, content, writer \\ "c_elsewhere") do
    {:ok, %{file: file}} =
      Durable.commit(&Projects.write_file_tx(&1, project.id, "notes.md", content, writer))

    file
  end

  defp content(view), do: view |> element("#file-content") |> render()

  defp open_notes(conn), do: live(conn, ~p"/projects/garden/files/notes.md")

  describe "a new file" do
    test "the page mounts", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/files/new")
      assert view |> element("#file-heading") |> render() =~ "New file"
      assert has_element?(view, ~s(#file-project[href="/projects/garden"]))
      assert has_element?(view, "#file-form #file-name")
      refute has_element?(view, "#file-delete")
      refute has_element?(view, "#file-meta")
    end

    test "is created through the form and opens on its page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects/garden/files/new")

      {:ok, view, _html} =
        view
        |> form("#file-form", file: %{name: "Plan", content: "# Plan\nWater daily."})
        |> render_submit()
        |> follow_redirect(conn, ~p"/projects/garden/files/Plan.md")

      assert view |> element("#file-heading") |> render() =~ "Plan.md"
      assert view |> element("#file-meta") |> render() =~ "Version 1, changed just now by you"
      assert content(view) =~ "Water daily."
    end

    test "saved from Preview, it opens on its page in Preview", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects/garden/files/new")
      view |> form("#file-form", file: %{name: "plan", content: "# Plan"}) |> render_change()
      view |> element("#file-tab-preview") |> render_click()

      {:ok, view, _html} =
        view
        |> form("#file-form", file: %{name: "plan", content: "# Plan"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/projects/garden/files/plan.md?tab=preview")

      assert has_element?(view, ~s(#file-tab-preview[aria-selected="true"]))
      assert has_element?(view, "#file-preview h1", "Plan")
    end

    test "a bad name shows the rule and keeps the text", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/garden/files/new")

      html =
        view
        |> form("#file-form", file: %{name: "../plan", content: "Water daily."})
        |> render_submit()

      assert html =~ "A file name uses letters, digits"
      assert content(view) =~ "Water daily."
      assert Enum.map(Projects.list_files(project.id), & &1.name) == ["notes.md"]
    end

    test "typing a name or text marks it unsaved", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects/garden/files/new")
      assert has_element?(view, ~s(#file-form[data-dirty="false"]))
      refute has_element?(view, "#file-dirty")

      view |> form("#file-form", file: %{name: "", content: "Water daily."}) |> render_change()
      assert has_element?(view, ~s(#file-form[data-dirty="true"]))
      assert has_element?(view, "#file-dirty")

      view |> form("#file-form", file: %{name: "plan", content: ""}) |> render_change()
      assert has_element?(view, "#file-dirty")

      view |> form("#file-form", file: %{name: " ", content: "\n"}) |> render_change()
      assert has_element?(view, ~s(#file-form[data-dirty="false"]))
      refute has_element?(view, "#file-dirty")
    end

    test "a name that is taken says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects/garden/files/new")

      html =
        view
        |> form("#file-form", file: %{name: "NOTES.md", content: "Again."})
        |> render_submit()

      assert html =~ "This project already has a file by that name."
    end
  end

  describe "an existing file" do
    test "is found by name, in any case", %{conn: conn, project: project} do
      for name <- ["notes.md", "Notes.md"] do
        {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/files/#{name}")
        assert view |> element("#file-heading") |> render() =~ "notes.md"
        assert content(view) =~ "Zone 2."
      end
    end

    test "saving bumps the version in the meta line", %{conn: conn, notes: notes} do
      {:ok, view, _html} = open_notes(conn)
      assert view |> element("#file-meta") |> render() =~ "Version 1, changed just now by you"

      assert has_element?(view, ~s(#file-form[data-dirty="false"]))

      assert has_element?(
               view,
               ~s(#file-form[phx-hook="PhotonWeb.EditorComponents.UnsavedGuard"])
             )

      assert has_element?(view, ~s(#file-content[phx-debounce]))

      view |> form("#file-form", file: %{content: "Zone 2 and 3."}) |> render_change()
      assert has_element?(view, "#file-dirty")
      assert has_element?(view, ~s(#file-form[data-dirty="true"]))

      view |> form("#file-form", file: %{content: "Zone 2 and 3."}) |> render_submit()

      assert view |> element("#file-meta") |> render() =~ "Version 2,"
      refute has_element?(view, "#file-dirty")
      refute has_element?(view, "#file-changed")

      assert %{version: 2, content: "Zone 2 and 3."} =
               Projects.get_file(notes.project_id, "notes")
    end

    test "a tick redraws the meta line from the loaded file", %{conn: conn} do
      {:ok, view, _html} = open_notes(conn)
      send(view.pid, :tick)
      # Aging itself is ProjectText's (test/web/project_text_test.exs) and
      # the project page's tick test; the editor keeps showing its version.
      assert view |> element("#file-meta") |> render() =~ "Version 1, changed just now by you"
    end

    test "the meta line names the thread that wrote it", %{conn: conn, project: project} do
      {:ok, thread} = Threads.start(project.id, "Fix the pump")
      await_idle(thread.id)
      _file = thread_writes(project, "Pump fixed.", thread.id)

      {:ok, view, _html} = open_notes(conn)

      assert view |> element("#file-meta") |> render() =~
               "Version 2, changed just now by &quot;Fix the pump&quot;"

      # The thread's new title, when the model names it or the owner renames it.
      {:ok, _thread} = Threads.rename(thread.id, "Pump check")
      _ = :sys.get_state(Durable.Store)
      assert view |> element("#file-meta") |> render() =~ "by &quot;Pump check&quot;"
    end

    test "the preview tab renders the Markdown, and the write tab comes back", %{conn: conn} do
      {:ok, view, _html} = open_notes(conn)
      refute has_element?(view, "#file-preview")

      view |> form("#file-form", file: %{content: "# Zones\n**Two** of them."}) |> render_change()
      view |> element("#file-tab-preview") |> render_click()

      assert has_element?(view, "#file-preview h1", "Zones")
      assert has_element?(view, "#file-preview strong", "Two")
      assert has_element?(view, ~s(#file-tab-preview[aria-selected="true"]))

      view |> element("#file-tab-write") |> render_click()
      refute has_element?(view, "#file-preview")
      assert content(view) =~ "**Two** of them."
    end

    test "saving from Preview stays in Preview", %{conn: conn} do
      {:ok, view, _html} = open_notes(conn)
      view |> form("#file-form", file: %{content: "# Zones"}) |> render_change()
      view |> element("#file-tab-preview") |> render_click()
      view |> form("#file-form", file: %{content: "# Zones"}) |> render_submit()

      assert view |> element("#file-meta") |> render() =~ "Version 2,"
      assert has_element?(view, ~s(#file-tab-preview[aria-selected="true"]))
      assert has_element?(view, "#file-preview h1", "Zones")
    end

    test "deleting it returns to the project", %{conn: conn, notes: notes} do
      {:ok, view, _html} = open_notes(conn)

      {:ok, _view, html} =
        view
        |> element("#file-delete")
        |> render_click()
        |> follow_redirect(conn, ~p"/projects/garden")

      assert html =~ "Deleted notes.md."
      assert Projects.get_file(notes.project_id, "notes.md") == nil
    end
  end

  describe "when a thread writes the open file" do
    test "a clean editor loads the new text", %{conn: conn, project: project} do
      {:ok, view, _html} = open_notes(conn)

      thread_writes(project, "Zone 3 leaks.")
      _ = render(view)

      assert content(view) =~ "Zone 3 leaks."

      assert view |> element("#file-meta") |> render() =~
               "Version 2, changed just now by a thread"

      # A new editor, so a focused textarea shows the new text too.
      assert has_element?(view, "#file-editor-1 #file-content")

      refute has_element?(view, "#file-changed")
    end

    test "a dirty editor keeps the text and offers the new version",
         %{conn: conn, project: project} do
      {:ok, view, _html} = open_notes(conn)
      view |> form("#file-form", file: %{content: "My draft."}) |> render_change()

      thread_writes(project, "Zone 3 leaks.")
      _ = render(view)

      assert has_element?(view, "#file-changed", "A thread changed this file")
      assert content(view) =~ "My draft."
      assert view |> element("#file-meta") |> render() =~ "Version 1,"

      view |> element("#file-reload") |> render_click()

      refute has_element?(view, "#file-changed")
      assert content(view) =~ "Zone 3 leaks."
      refute content(view) =~ "My draft."
      assert view |> element("#file-meta") |> render() =~ "Version 2,"
    end

    test "keeping the text lets the next save write over the thread's",
         %{conn: conn, project: project} do
      {:ok, view, _html} = open_notes(conn)
      view |> form("#file-form", file: %{content: "My draft."}) |> render_change()
      thread_writes(project, "Zone 3 leaks.")
      _ = render(view)

      view |> element("#file-keep") |> render_click()
      refute has_element?(view, "#file-changed")
      assert content(view) =~ "My draft."

      view |> form("#file-form") |> render_submit()

      refute has_element?(view, "#file-changed")
      assert %{version: 3, content: "My draft."} = Projects.get_file(project.id, "notes.md")
    end

    test "a save with an old version shows the banner and keeps the text",
         %{conn: conn, project: project} do
      {:ok, view, _html} = open_notes(conn)
      thread_writes(project, "Zone 3 leaks.")
      _ = render(view)

      # The hidden version an editor that missed the write would still send.
      view
      |> form("#file-form", file: %{content: "Typed over v1."})
      |> render_submit(%{file: %{version: "1"}})

      assert has_element?(view, "#file-changed")
      assert content(view) =~ "Typed over v1."
      assert %{version: 2, content: "Zone 3 leaks."} = Projects.get_file(project.id, "notes.md")
    end

    test "a deleted file says so, and saving creates it again", %{conn: conn, project: project} do
      {:ok, view, _html} = open_notes(conn)
      view |> form("#file-form", file: %{content: "Keep this."}) |> render_change()

      :ok = Projects.delete_file(project.id, "notes.md")
      _ = render(view)

      assert has_element?(view, "#file-deleted")
      assert content(view) =~ "Keep this."

      view |> form("#file-form") |> render_submit()

      refute has_element?(view, "#file-deleted")
      assert %{version: 1, content: "Keep this."} = Projects.get_file(project.id, "notes.md")
    end

    test "a change to another file leaves the editor alone", %{conn: conn, project: project} do
      {:ok, view, _html} = open_notes(conn)
      view |> form("#file-form", file: %{content: "My draft."}) |> render_change()

      {:ok, _plan} = Projects.create_file(project.id, %{name: "plan.md", content: "Water."})
      _ = render(view)

      refute has_element?(view, "#file-changed")
      assert content(view) =~ "My draft."
    end
  end

  describe "when Blip writes the open file" do
    test "the meta line says Blip wrote it", %{conn: conn, project: project} do
      _file = thread_writes(project, "Zone 3 leaks.", "blip")

      {:ok, view, _html} = open_notes(conn)

      assert view |> element("#file-meta") |> render() =~
               "Version 2, changed just now by Blip"
    end

    test "a dirty editor's banner names Blip", %{conn: conn, project: project} do
      {:ok, view, _html} = open_notes(conn)
      view |> form("#file-form", file: %{content: "My draft."}) |> render_change()

      thread_writes(project, "Zone 3 leaks.", "blip")
      _ = render(view)

      assert has_element?(
               view,
               "#file-changed",
               "Blip changed this file while you were editing."
             )

      refute has_element?(view, "#file-changed", "A thread")
      assert content(view) =~ "My draft."
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

  # Waits until thread `id` has answered, so no run outlives the test.
  defp await_idle(id) do
    :ok = Threads.subscribe(id)
    if Threads.busy?(id), do: await_change(id, fn _changes -> not Threads.busy?(id) end)
    :ok
  end
end
