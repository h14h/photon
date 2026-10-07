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

  test "each phrasing matches the whole message" do
    for text <- ["projects please", "project", "threads in", "read thread", "the threads"] do
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
    assert help =~ MockCoordinator.help()
  end

  test "relays what a read tool said" do
    listed = ~s(c_1 "Fix the pump" \(garden\): failed: the pump is unplugged)
    result = Message.tool_result("call_1", listed)
    request = %{messages: [Message.user("threads"), Message.assistant("", []), result]}
    assert Message.text_of(MockScript.respond(request)) == listed
  end
end
