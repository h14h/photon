defmodule Photon.ThreadFileToolsTest do
  @moduledoc """
  A thread's context-file tools, driven through the scripted model: each
  message is one tool call, and the test reads the tool's result and the
  file it left. That a stopped call keeps none of its commit's writes is the
  harness's `{:commit, fun}` contract (`Photon.Durable.Tool`);
  `test/boundary/projects_test.exs` covers a rolled-back `write_file_tx/5`.
  """

  use Photon.DataCase, async: false

  @moduletag :durable

  alias Photon.{Projects, Threads}
  alias Photon.Projects.ContextFile

  setup do
    {:ok, project} =
      Projects.create(%{"purpose" => "Keep the garden watered.", "name" => "Garden"})

    {:ok, thread} = Threads.start(project.id, "hello")
    :ok = Threads.subscribe(thread.id)
    await_entry(thread.id, &(&1.kind == "assistant"))
    %{project: project, thread: thread.id}
  end

  # Sends `text` and returns the result of the tool call it makes.
  defp tool(thread, text) do
    {:ok, submission} = Threads.send(thread, text)
    _settled = await_settled(thread, submission.id)
    thread |> Durable.entries() |> Enum.filter(&(&1.kind == "tool_result")) |> List.last()
  end

  defp text(entry), do: PhotonCore.Message.text_of(entry.data["message"])

  test "write creates a file as written by the thread, and announces it", %{
    project: project,
    thread: thread
  } do
    :ok = Projects.subscribe_files(project.id)

    result = tool(thread, "write notes.md: hello")
    assert text(result) == "Created notes.md (5 characters)."
    assert result.data["details"] == %{"file" => "notes.md", "version" => 1}

    project_id = project.id
    assert_receive {:project_files_changed, ^project_id, "notes.md"}

    assert %ContextFile{content: "hello", version: 1, updated_by: ^thread} =
             Projects.get_file(project.id, "notes.md")

    assert text(tool(thread, "write notes.md: hello, world")) ==
             "Wrote notes.md (12 characters)."

    assert %ContextFile{content: "hello, world", version: 2} =
             Projects.get_file(project.id, "notes.md")
  end

  test "read returns the file after a line about it", %{project: project, thread: thread} do
    {:ok, _file} = Projects.create_file(project.id, %{"name" => "notes.md", "content" => "hello"})

    assert text(tool(thread, "read notes.md")) =~
             ~r/\Anotes\.md, 5 characters, changed \d{4}-\d\d-\d\d \d\d:\d\d UTC by the user:\nhello\z/
  end

  test "read of a missing file lists the names there are", %{project: project, thread: thread} do
    assert text(tool(thread, "read todo.md")) ==
             "Error: There's no todo.md. This project has no context files yet."

    {:ok, _file} = Projects.create_file(project.id, %{"name" => "notes.md", "content" => "hi"})

    assert text(tool(thread, "read todo.md")) ==
             "Error: There's no todo.md. This project's context files are: notes.md."
  end

  test "edit changes one passage; text that isn't there changes nothing", %{
    project: project,
    thread: thread
  } do
    _created = tool(thread, "write notes.md: hello there")

    assert text(tool(thread, "edit notes.md: hello => bye")) ==
             "Edited notes.md (9 characters now)."

    assert %ContextFile{content: "bye there", version: 2, updated_by: ^thread} =
             Projects.get_file(project.id, "notes.md")

    assert text(tool(thread, "edit notes.md: hello => bye")) ==
             "Error: old_text wasn't found in notes.md."

    assert %ContextFile{content: "bye there", version: 2} =
             Projects.get_file(project.id, "notes.md")
  end

  test "a refused write changes nothing", %{project: project, thread: thread} do
    assert text(tool(thread, "write ../notes.md: hello")) =~ "Error: A file name uses letters"
    assert Projects.list_files(project.id) == []
  end

  test "files lists them, naming who changed each", %{project: project, thread: thread} do
    assert text(tool(thread, "files")) == "This project has no context files yet."

    {:ok, other} = Threads.start(project.id, "write zones.md: three zones")
    :ok = Threads.subscribe(other.id)
    await_entry(other.id, &(&1.kind == "tool_result"))

    _written = tool(thread, "write notes.md: hello")
    {:ok, _file} = Projects.create_file(project.id, %{"name" => "plan.md", "content" => ""})

    lines = thread |> tool("files") |> text() |> String.split("\n")

    assert [
             "- plan.md (0 characters, changed " <> plan,
             "- notes.md (5 characters, changed " <> notes,
             "- zones.md (11 characters, changed " <> zones
           ] = lines

    assert plan =~ ~r/ UTC by the user\)\z/
    assert notes =~ ~r/ UTC by you\)\z/
    assert zones =~ ~r/ UTC by thread "write zones.md: three zones"\)\z/
  end

  test "a file Blip wrote reads as Blip's", %{project: project, thread: thread} do
    {:ok, _written} =
      Durable.commit(&Projects.write_file_tx(&1, project.id, "notes.md", "hello", "blip"))

    assert text(tool(thread, "files")) =~
             ~r/\A- notes\.md \(5 characters, changed .* UTC by Blip\)\z/

    assert text(tool(thread, "read notes.md")) =~
             ~r/\Anotes\.md, 5 characters, changed .* by Blip:\nhello\z/
  end
end
