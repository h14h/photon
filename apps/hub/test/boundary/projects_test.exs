defmodule Photon.ProjectsTest do
  @moduledoc """
  `Photon.Projects` through its API, against the real database and Store.
  The rules themselves are covered in `test/core/projects/rules_test.exs`.
  """

  use Photon.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Photon.Durable.Tx
  alias Photon.{Projects, Signals}
  alias Photon.Projects.{ContextFile, Project}
  alias Photon.Signals.DigestItem

  # Writes go through the Store's commit line.
  @moduletag :durable

  @purpose "Keep the garden's irrigation running through winter. It has three zones."

  defp project!(params \\ %{"purpose" => @purpose, "name" => "Garden"}) do
    {:ok, project} = Projects.create(params)
    project
  end

  defp write(project_id, name, content) do
    Durable.commit(&Projects.write_file_tx(&1, project_id, name, content, "c_thread"))
  end

  defp edit(project_id, name, old_text, new_text) do
    Durable.commit(&Projects.edit_file_tx(&1, project_id, name, old_text, new_text, "c_thread"))
  end

  describe "projects" do
    test "create/1 makes the slug from the name and announces the project" do
      :ok = Projects.subscribe()

      assert {:ok,
              %Project{id: "p_" <> _ = id, slug: "garden", name: "Garden", purpose: @purpose}} =
               Projects.create(%{"purpose" => @purpose, "name" => " Garden "})

      assert_receive {:projects_changed, ^id}
      assert %Project{slug: "garden"} = Projects.get(id)
      assert %Project{id: ^id} = Projects.get_by_slug("garden")
    end

    test "create/1 derives a blank name from the purpose" do
      assert {:ok, %Project{name: "Keep the garden's irrigation running", slug: slug}} =
               Projects.create(%{purpose: @purpose})

      assert slug == "keep-the-garden-s-irrigation-running"
    end

    test "two projects with one name get distinct slugs" do
      assert %Project{slug: "garden"} = project!()

      assert %Project{slug: "garden-more"} =
               project!(%{"purpose" => "x", "name" => "Garden more"})

      assert %Project{slug: "garden-2"} = project!()
      assert %Project{slug: "garden-3"} = project!()
    end

    test "errors come back as a field map and nothing is made" do
      :ok = Projects.subscribe()

      assert Projects.create(%{"purpose" => " ", "name" => "Garden"}) ==
               {:error, %{purpose: "Say what the project is for."}}

      assert Projects.list() == []
      refute_received {:projects_changed, _}
    end

    test "update/2 changes the name and purpose, keeps the slug and announces" do
      project = project!()
      :ok = Projects.subscribe()

      assert {:ok, %Project{name: "Yard", slug: "garden", purpose: "Mow it."}} =
               Projects.update(project.id, %{"name" => "Yard", "purpose" => "Mow it."})

      id = project.id
      assert_receive {:projects_changed, ^id}

      assert {:ok, %Project{name: "Mow it", slug: "garden"}} =
               Projects.update(project.id, %{"name" => ""})

      assert {:error, %{purpose: _}} = Projects.update(project.id, %{"purpose" => ""})
      assert Projects.get(id).name == "Mow it"

      assert Projects.update("p_missing", %{"name" => "x"}) == {:error, :not_found}
    end

    test "list/0 orders by name" do
      project!(%{"purpose" => "x", "name" => "zebra"})
      project!(%{"purpose" => "x", "name" => "Apple"})
      assert Enum.map(Projects.list(), & &1.name) == ["Apple", "zebra"]
    end
  end

  describe "context files, for the user" do
    setup do
      project = project!()
      :ok = Projects.subscribe_files(project.id)
      %{project: project}
    end

    test "create_file/2 stores a new file at version 1 and announces it", %{project: p} do
      pid = p.id

      assert {:ok,
              %ContextFile{name: "Notes.md", key: "notes.md", version: 1, updated_by: "owner"}} =
               Projects.create_file(p.id, %{"name" => "Notes", "content" => "hello"})

      assert_receive {:project_files_changed, ^pid, "notes.md"}
      assert %ContextFile{content: "hello"} = Projects.get_file(p.id, "NOTES.MD")
      assert %ContextFile{} = Projects.get_file(p.id, "notes")
      assert [%ContextFile{name: "Notes.md"}] = Projects.list_files(p.id)
    end

    test "a taken name, in any case, is :exists", %{project: p} do
      {:ok, _} = Projects.create_file(p.id, %{name: "notes.md", content: ""})
      assert Projects.create_file(p.id, %{name: "NOTES.md", content: "x"}) == {:error, :exists}
      assert Projects.get_file(p.id, "notes.md").content == ""
    end

    test "a bad name or content is a field error", %{project: p} do
      assert {:error, %{name: "A file name uses" <> _}} =
               Projects.create_file(p.id, %{"name" => "a/b", "content" => ""})

      assert {:error, %{content: "notes.md would be 100,001 characters" <> _}} =
               Projects.create_file(p.id, %{
                 "name" => "notes",
                 "content" => String.duplicate("a", 100_001)
               })

      assert Projects.list_files(p.id) == []
    end

    test "a missing project is :not_found" do
      assert Projects.create_file("p_missing", %{"name" => "a", "content" => ""}) ==
               {:error, :not_found}
    end

    test "save_file/4 with the loaded version bumps it; an old one is :stale", %{project: p} do
      pid = p.id
      {:ok, _} = Projects.create_file(p.id, %{"name" => "notes", "content" => "one"})
      assert_receive {:project_files_changed, ^pid, "notes.md"}

      assert {:ok, %ContextFile{version: 2, content: "two"}} =
               Projects.save_file(p.id, "notes.md", "two", 1)

      assert_receive {:project_files_changed, ^pid, "notes.md"}

      assert Projects.save_file(p.id, "notes.md", "stale", 1) == {:error, :stale}
      refute_received {:project_files_changed, _, _}
      assert Projects.get_file(p.id, "notes.md").content == "two"
    end

    test "delete_file/2 deletes and announces; saving the old version creates it again",
         %{project: p} do
      pid = p.id
      {:ok, _} = Projects.create_file(p.id, %{"name" => "notes", "content" => "one"})
      assert_receive {:project_files_changed, ^pid, "notes.md"}

      assert Projects.delete_file(p.id, "Notes.md") == :ok
      assert_receive {:project_files_changed, ^pid, "notes.md"}
      assert Projects.get_file(p.id, "notes.md") == nil
      assert Projects.delete_file(p.id, "notes.md") == {:error, :not_found}

      assert {:ok, %ContextFile{version: 1}} = Projects.save_file(p.id, "notes.md", "back", 1)
    end
  end

  describe "context files, for thread tools" do
    setup do
      project = project!()
      :ok = Projects.subscribe_files(project.id)
      %{project: project}
    end

    test "write_file_tx/5 creates, then replaces without a version check", %{project: p} do
      pid = p.id

      assert {:ok, %{created?: true, file: %ContextFile{version: 1, updated_by: "c_thread"}}} =
               write(p.id, "notes", "hello")

      assert_receive {:project_files_changed, ^pid, "notes.md"}

      assert {:ok, %{created?: false, file: %ContextFile{version: 2, content: "bye"}}} =
               write(p.id, "Notes.md", "bye")

      assert_receive {:project_files_changed, ^pid, "notes.md"}
      assert [%ContextFile{name: "notes.md", content: "bye"}] = Projects.list_files(p.id)
    end

    test "write_file_tx/5 refuses a bad name or content with a message, changing nothing",
         %{project: p} do
      assert {:error, "A file name uses" <> _} = write(p.id, "../etc/passwd", "x")

      assert {:error, "notes.md would be 100,001 characters" <> _} =
               write(p.id, "notes.md", String.duplicate("a", 100_001))

      assert {:error, "This thread's project no longer exists."} = write("p_missing", "a", "x")

      assert Projects.list_files(p.id) == []
      refute_received {:project_files_changed, _, _}
    end

    test "write_file_tx/5 in a commit that rolls back leaves no file and no announcement",
         %{project: p} do
      assert {:rolled_back, :stopped} =
               Durable.commit(fn tx ->
                 {:ok, _} = Projects.write_file_tx(tx, p.id, "notes", "hello", "c_thread")
                 Tx.rollback(:stopped)
               end)

      assert Projects.list_files(p.id) == []
      refute_received {:project_files_changed, _, _}
    end

    test "edit_file_tx/6 replaces a passage found once", %{project: p} do
      pid = p.id
      {:ok, _} = write(p.id, "notes", "zone 2 stuck")
      assert_receive {:project_files_changed, ^pid, "notes.md"}

      assert {:ok, %ContextFile{content: "zone 2 fixed", version: 2, updated_by: "c_other"}} =
               Durable.commit(
                 &Projects.edit_file_tx(&1, p.id, "NOTES", "stuck", "fixed", "c_other")
               )

      assert_receive {:project_files_changed, ^pid, "notes.md"}
    end

    test "edit_file_tx/6 errors change nothing", %{project: p} do
      pid = p.id
      {:ok, _} = write(p.id, "notes", "ok ok ok")
      {:ok, _} = write(p.id, "plan", "")
      assert_receive {:project_files_changed, ^pid, "notes.md"}
      assert_receive {:project_files_changed, ^pid, "plan.md"}

      assert edit(p.id, "notes", "missing", "x") ==
               {:error, "old_text wasn't found in notes.md."}

      assert edit(p.id, "notes", "ok", "x") ==
               {:error, "old_text appears 3 times in notes.md; give more of the passage."}

      assert {:error, "notes.md would be 100,002 characters" <> _} =
               edit(p.id, "notes", "ok ok ok", String.duplicate("a", 100_002))

      assert {:error, "There's no zones.md. This project's context files are: " <> names} =
               edit(p.id, "zones", "a", "b")

      assert names =~ "notes.md"
      assert names =~ "plan.md"

      assert %ContextFile{content: "ok ok ok", version: 1} = Projects.get_file(p.id, "notes")
      refute_received {:project_files_changed, _, _}
    end

    test "a missing project's message names the writer's side" do
      assert write("p_missing", "a", "x") ==
               {:error, "This thread's project no longer exists."}

      assert edit("p_missing", "a", "x", "y") ==
               {:error, "This thread's project no longer exists."}

      assert Durable.commit(&Projects.write_file_tx(&1, "p_missing", "a", "x", "blip")) ==
               {:error, "That project no longer exists."}

      assert Durable.commit(&Projects.edit_file_tx(&1, "p_missing", "a", "x", "y", "blip")) ==
               {:error, "That project no longer exists."}
    end

    test "Blip writes and edits as blip", %{project: p} do
      assert {:ok, %{created?: true, file: %ContextFile{updated_by: "blip"}}} =
               Durable.commit(&Projects.write_file_tx(&1, p.id, "notes", "zone 2", "blip"))

      assert {:ok, %ContextFile{content: "zone 3", version: 2, updated_by: "blip"}} =
               Durable.commit(&Projects.edit_file_tx(&1, p.id, "notes", "2", "3", "blip"))
    end

    test "edit_file_tx/6 on a project with no files says so" do
      empty = project!(%{"purpose" => "x", "name" => "Empty"})

      assert edit(empty.id, "notes", "a", "b") ==
               {:error, "There's no notes.md. This project has no context files yet."}
    end
  end

  describe "digest items" do
    defp ambient!(on?) do
      _doc = Durable.commit(&Signals.put_ambient_doc_tx(&1, %{"on" => on?}))
      :ok
    end

    defp items do
      query = from(i in DigestItem, order_by: [asc: i.inserted_at, asc: i.id])
      for i <- Repo.all(query), do: {i.kind, i.project_id, i.name, i.writer, i.note}
    end

    test "with ambient mode on, the owner's project and file changes collect one per subject" do
      ambient!(true)
      p = project!()
      assert [{"project_created", p.id, nil, nil, nil}] == items()

      {:ok, _project} = Projects.update(p.id, %{"purpose" => "Keep the garden green."})
      {:ok, _file} = Projects.create_file(p.id, %{"name" => "notes", "content" => "a"})
      assert length(items()) == 3

      # The same file saved and deleted: its row is replaced by the newest
      # change, so the table holds one row for it however often it changes.
      {:ok, _file} = Projects.save_file(p.id, "notes.md", "b", 1)
      assert Projects.delete_file(p.id, "notes") == :ok

      assert [
               {"project_created", p.id, nil, nil, nil},
               {"purpose_changed", p.id, nil, nil, nil},
               {"file_written", p.id, "notes.md", "user", "deleted"}
             ] == items()

      keys = Repo.all(from(i in DigestItem, select: i.key))

      assert Enum.sort(keys) ==
               Enum.sort([
                 "project_created:" <> p.id,
                 "purpose_changed:" <> p.id,
                 "file_written:#{p.id}:notes.md"
               ])
    end

    test "an update that changes nothing, and a refused change, collect nothing" do
      p = project!()
      ambient!(true)

      {:ok, _project} = Projects.update(p.id, %{"purpose" => @purpose, "name" => "Garden"})
      assert {:error, %{purpose: _}} = Projects.update(p.id, %{"purpose" => " "})
      assert {:error, %{}} = Projects.create(%{"purpose" => ""})
      {:ok, _file} = Projects.create_file(p.id, %{"name" => "notes", "content" => "a"})

      assert Projects.create_file(p.id, %{"name" => "notes", "content" => "b"}) ==
               {:error, :exists}

      assert Projects.save_file(p.id, "notes", "c", 7) == {:error, :stale}
      assert Projects.delete_file(p.id, "missing") == {:error, :not_found}

      assert [{"file_written", p.id, "notes.md", "user", nil}] == items()
    end

    test "a thread's writes and edits to one file collect one row, under the thread's ID" do
      p = project!()
      ambient!(true)

      {:ok, _written} = write(p.id, "notes", "zone 2")
      assert [{"file_written", p.id, "notes.md", "c_thread", nil}] == items()

      for n <- 3..20, do: {:ok, _edited} = edit(p.id, "notes", "#{n - 1}", "#{n}")
      {:error, _message} = edit(p.id, "notes", "nowhere", "x")

      assert [{"file_written", p.id, "notes.md", "c_thread", nil}] == items()
    end

    test "Blip's writes and projects collect nothing" do
      p = project!(%{"purpose" => "x", "name" => "Shed"})
      ambient!(true)

      {:ok, _written} =
        Durable.commit(&Projects.write_file_tx(&1, p.id, "notes", "zone 2", "blip"))

      {:ok, _edited} =
        Durable.commit(&Projects.edit_file_tx(&1, p.id, "notes", "2", "3", "blip"))

      {:ok, _project} = Durable.commit(&Projects.create_tx(&1, %{"purpose" => @purpose}))

      assert items() == []
    end

    test "with ambient mode off, nothing is collected" do
      ambient!(false)
      p = project!()
      {:ok, _project} = Projects.update(p.id, %{"name" => "Garden beds"})
      {:ok, _file} = Projects.create_file(p.id, %{"name" => "notes", "content" => "a"})
      {:ok, _written} = write(p.id, "notes", "zone 2")
      {:ok, _edited} = edit(p.id, "notes", "2", "3")
      assert Projects.delete_file(p.id, "notes") == :ok

      assert items() == []
    end
  end
end
