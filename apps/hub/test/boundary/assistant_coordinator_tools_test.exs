defmodule Photon.AssistantCoordinatorToolsTest do
  @moduledoc """
  Blip's tools over projects and threads (section 5 of
  `docs/plans/step-4-blip-as-coordinator.md`), driven through the scripted
  Blip on the durable harness: what each returns, and what it changed.
  The texts themselves are covered in `test/core/assistant/readout_test.exs`;
  here, that the tools read the right rows and name what they read.
  """

  use Photon.DataCase, async: false

  @moduletag :durable

  alias Photon.{Assistant, Projects, Questions, Schedules, Skills, Threads}
  alias PhotonCore.Message

  setup do
    {:ok, garden} =
      Projects.create(%{
        "purpose" => "Keep the vegetable beds watered. And the pump running.",
        "name" => "Garden"
      })

    {:ok, house} =
      Projects.create(%{"purpose" => "Fix things around the house.", "name" => "House"})

    blip = Assistant.conversation_id()
    :ok = Durable.subscribe(blip)
    %{garden: garden, house: house, blip: blip}
  end

  defp idle!(conversation_id) do
    :ok = Durable.subscribe(conversation_id)

    if Durable.busy?(conversation_id),
      do: await_change(conversation_id, fn _changes -> not Durable.busy?(conversation_id) end)

    :ok
  end

  # Starts a thread with the owner's message and waits until its run has
  # ended and Blip has heard about it, if it was going to.
  defp ended!(project, text) do
    {:ok, thread} = Threads.start(project.id, text)
    :ok = idle!(thread.id)
    :ok = idle!(Assistant.conversation_id())
    thread
  end

  # Sends Blip `text` once it is idle and returns the result of the tool
  # call its answer made: the text and the result's data.
  defp tool!(blip, text, name) do
    :ok = idle!(blip)
    {:ok, s} = Assistant.send(text)
    await_settled(blip, s.id)

    entry =
      blip
      |> Durable.entries()
      |> Enum.filter(&(&1.kind == "tool_result"))
      |> List.last()

    assert entry.data["name"] == name
    {Message.text_of(entry.data["message"]), entry.data}
  end

  describe "list_projects" do
    test "every project with its threads' states and its files", %{garden: garden, blip: blip} do
      _failed = ended!(garden, "fail: the pump is unplugged")
      _asked = ended!(garden, "ask me: which seeds should I order")
      {:ok, _file} = Projects.create_file(garden.id, %{"name" => "notes.md", "content" => "Hi."})

      {text, data} = tool!(blip, "projects", "list_projects")
      assert data["status"] == "ok"

      assert text ==
               "garden: Garden. Keep the vegetable beds watered. 1 waiting on the user, " <>
                 "1 failed. 1 context file.\n" <>
                 "house: House. Fix things around the house. No threads. No context files."
    end
  end

  describe "read_project" do
    test "by slug or ID: purpose, files, threads, schedules and skills", %{
      garden: garden,
      blip: blip
    } do
      failed = ended!(garden, "fail: the pump is unplugged")
      {:ok, _file} = Projects.create_file(garden.id, %{"name" => "notes.md", "content" => "Hi."})

      {:ok, skill} =
        Skills.create(%{
          "name" => "pdf-forms",
          "description" => "Fill in PDF forms.",
          "instructions" => "# PDF forms\n\nFill each field."
        })

      :ok = Skills.enable(skill.id, {:project, garden.id})

      params =
        Map.merge(Schedules.new_params(DateTime.utc_now()), %{
          "prompt" => "check the beds",
          "target" => failed.id
        })

      {:ok, schedule} = Schedules.create({:project, garden.id}, params)

      {text, data} = tool!(blip, "project garden", "read_project")
      assert data["details"] == %{"project_id" => garden.id, "slug" => "garden"}

      assert text =~
               "Garden (garden, ID #{garden.id})\n" <>
                 "Purpose: Keep the vegetable beds watered. And the pump running.\n\n"

      assert text =~ ~r/Context files:\n- notes\.md \(3 characters, changed .* by the user\)/

      assert text =~
               ~s(Threads \(1, most recent first\):\n- #{failed.id} "#{failed.title}": failed)

      assert text =~ ~s(- #{schedule.id}: )
      assert text =~ ~s(wakes #{failed.id} "#{failed.title}": "check the beds")
      assert text =~ "Skills on: pdf-forms."

      {by_id, _data} = tool!(blip, "project #{garden.id}", "read_project")
      assert by_id == text
    end

    test "an unknown project lists the slugs there are", %{blip: blip} do
      {text, data} = tool!(blip, "project gardn", "read_project")
      assert data["status"] == "error"
      assert text == "Error: There's no project called gardn. Projects: garden, house."
    end
  end

  describe "list_threads" do
    test "every thread, or a project's, with open questions", %{
      garden: garden,
      house: house,
      blip: blip
    } do
      failed = ended!(garden, "fail: the pump is unplugged")

      # The asking thread's run waits for the answer, so it stays busy.
      :ok = Questions.subscribe()
      {:ok, asking} = Threads.start(house.id, "ask blip: what colour should the gate be?")
      asking_id = asking.id
      assert_receive {:questions_changed, ^asking_id}, 5_000
      assert %{^asking_id => [question]} = Questions.open_by_thread([asking_id])

      {text, _data} = tool!(blip, "threads", "list_threads")
      lines = String.split(text, "\n")
      assert length(lines) == 2

      first = hd(lines)
      assert String.starts_with?(first, ~s(#{asking_id} "#{asking.title}" \(house\): ))
      assert first =~ "question #{question.id}, "
      assert first =~ ": what colour should the gate be?"

      assert List.last(lines) ==
               ~s(#{failed.id} "#{failed.title}" \(garden\): failed: ) <>
                 "HTTP 500: the pump is unplugged"

      {text, data} = tool!(blip, "threads in garden", "list_threads")
      assert text == List.last(lines)
      assert data["details"] == %{"project_id" => garden.id, "slug" => "garden"}
    end

    test "an empty list says so, and an unknown project is an error", %{blip: blip} do
      {text, _data} = tool!(blip, "threads", "list_threads")
      assert text == "No threads."

      {text, _data} = tool!(blip, "threads in house", "list_threads")
      assert text == "No threads in house."

      {text, data} = tool!(blip, "threads in shed", "list_threads")
      assert data["status"] == "error"
      assert text == "Error: There's no project called shed. Projects: garden, house."
    end
  end

  describe "read_thread" do
    test "the header and the latest items, without marking the thread seen", %{
      garden: garden,
      blip: blip
    } do
      thread = ended!(garden, "files")
      before = Threads.get(thread.id)
      assert before.last_run_status == "done"

      {text, data} = tool!(blip, "read thread #{thread.id}", "read_thread")

      assert data["details"] == %{
               "thread_id" => thread.id,
               "project_id" => garden.id,
               "title" => thread.title
             }

      assert text =~ ~s("#{thread.title}" \(#{thread.id}\), in Garden \(garden\)\n)
      assert text =~ "State: finished, not yet seen by the user\n"
      assert text =~ "Started by the user; last activity "

      assert String.ends_with?(
               text,
               "\n\n[user] files\n[thread] Checking the context files.\n" <>
                 "[tool] Listed the context files\n[thread] This project has no context files yet."
             )

      assert Threads.get(thread.id).seen_at == before.seen_at
      assert Threads.state(thread.id).state == :unread
    end

    test "an unknown thread points to list_threads", %{blip: blip} do
      {text, data} = tool!(blip, "read thread c_999", "read_thread")
      assert data["status"] == "error"
      assert text == "Error: There's no thread c_999. list_threads shows them."
    end
  end
end
