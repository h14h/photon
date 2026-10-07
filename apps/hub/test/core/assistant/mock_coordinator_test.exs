defmodule Photon.Assistant.MockCoordinatorTest do
  @moduledoc """
  The scripted Blip's phrasings for its tools over projects and threads
  (section 8.2 of `docs/plans/step-4-blip-as-coordinator.md`), on their
  own and through `Photon.Assistant.MockScript`, which tries them.
  """

  use Photon.Case, async: true

  alias Photon.Assistant.{MockCoordinator, MockScript}

  defp ask(text), do: MockScript.respond(%{messages: [Message.user(text)]})

  defp calls(message), do: Enum.map(Message.tool_calls(message), &{&1["name"], args(&1)})

  defp args(call) do
    {:ok, args} = Message.arguments(call)
    args
  end

  test "the read phrasings call the read tools" do
    for {text, call} <- [
          {"projects", {"list_projects", %{}}},
          {"list projects", {"list_projects", %{}}},
          {"project garden", {"read_project", %{"project" => "garden"}}},
          {"threads", {"list_threads", %{}}},
          {"threads in garden", {"list_threads", %{"project" => "garden"}}},
          {"read thread c_123", {"read_thread", %{"thread" => "c_123"}}}
        ] do
      assert calls(ask(text)) == [call], text
    end
  end

  test "the phrasings that start and stop work call their tools" do
    for {text, call} <- [
          {"start project: Keep the beds watered.",
           {"start_project", %{"purpose" => "Keep the beds watered."}}},
          {"start thread in garden: on local: $ echo hi",
           {"start_thread", %{"project" => "garden", "message" => "on local: $ echo hi"}}},
          {"tell c_123: check the pump again",
           {"message_thread", %{"thread" => "c_123", "message" => "check the pump again"}}},
          {"stop thread c_123", {"stop_thread", %{"thread" => "c_123"}}}
        ] do
      assert calls(ask(text)) == [call], text
    end
  end

  test "the file phrasings name a project and a file, and call the file tools" do
    for {text, call} <- [
          {"files in garden", {"list_context_files", %{"project" => "garden"}}},
          {"read garden/notes.md",
           {"read_context_file", %{"project" => "garden", "name" => "notes.md"}}},
          {"write garden/notes.md: # Beds\n\nWater zone 2.",
           {"write_context_file",
            %{"project" => "garden", "name" => "notes.md", "content" => "# Beds\n\nWater zone 2."}}},
          {"edit garden/notes.md: zone 2 => zone 3",
           {"edit_context_file",
            %{
              "project" => "garden",
              "name" => "notes.md",
              "old_text" => "zone 2",
              "new_text" => "zone 3"
            }}}
        ] do
      assert calls(ask(text)) == [call], text
    end

    # A thread is read by its ID, never as a file.
    assert calls(ask("read thread c_123")) == [{"read_thread", %{"thread" => "c_123"}}]
  end

  test "each phrasing matches the whole message" do
    for text <- [
          "projects please",
          "project",
          "threads in",
          "read thread",
          "the threads",
          "start project",
          "start thread in garden",
          "tell c_123",
          "stop thread",
          "stop thread c_1 now",
          "files in",
          "read notes.md",
          "read garden/notes.md now",
          "write garden: hello",
          "edit garden/notes.md: zone 2"
        ] do
      assert calls(ask(text)) == [], text
    end
  end

  test "a scheduled prompt can use them too" do
    assert calls(ask("[Scheduled] threads in garden")) ==
             [{"list_threads", %{"project" => "garden"}}]
  end

  test "the phrasings are a list of patterns with replies, and the help lists them" do
    for {pattern, reply} <- MockCoordinator.phrasings(%{}) do
      assert %Regex{} = pattern
      assert is_function(reply, 1)
    end

    help = Message.text_of(ask("what can you do?"))
    assert help =~ "`projects` lists the projects"
    assert help =~ "`read thread <id>` reads one"
    assert help =~ "`start thread in <slug>: <message>` starts a thread there"
    assert help =~ "`stop thread <id>` stops one"
    assert help =~ "`write <slug>/<name>: <text>` writes a whole file"
    assert help =~ MockCoordinator.help()
  end

  test "relays what a read tool said" do
    listed = ~s(c_1 "Fix the pump" \(garden\): failed: the pump is unplugged)
    result = Message.tool_result("call_1", listed)
    request = %{messages: [Message.user("threads"), Message.assistant("", []), result]}
    assert Message.text_of(MockScript.respond(request)) == listed
  end
end
