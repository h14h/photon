defmodule Photon.Assistant.MockScriptTest do
  @moduledoc "The mock assistant model's fixed phrasings."

  use Photon.Case, async: true

  alias Photon.Assistant.{MockScript, Report}

  defp ask(text), do: MockScript.respond(%{messages: [Message.user(text)]})

  defp calls(message), do: Enum.map(Message.tool_calls(message), &{&1["name"], args(&1)})

  defp args(call) do
    {:ok, args} = Message.arguments(call)
    args
  end

  test "lists nodes" do
    assert calls(ask("nodes")) == [{"list_nodes", %{}}]
  end

  test "hands a task to a node" do
    assert calls(ask("on mp1: $ uptime")) ==
             [{"run_on_node", %{"node" => "mp1", "task" => "$ uptime", "wait_seconds" => 5}}]
  end

  test "checks a session, remembers, and schedules" do
    assert calls(ask("check ns_1")) == [{"check_node_session", %{"session_id" => "ns_1"}}]

    assert calls(ask("remember the NAS is mp1")) ==
             [{"update_memory", %{"action" => "add", "text" => "the NAS is mp1"}}]

    assert calls(ask("in 2 minutes: nodes")) ==
             [{"schedule", %{"prompt" => "nodes", "in_minutes" => 2}}]

    assert calls(ask("every 30 minutes: nodes")) ==
             [{"schedule", %{"prompt" => "nodes", "every_minutes" => 30}}]

    assert calls(ask("schedules")) == [{"list_schedules", %{}}]
  end

  test "acts on a scheduled prompt as if the user asked" do
    assert calls(ask("[Scheduled] nodes")) == [{"list_nodes", %{}}]
  end

  test "relays a tool's result without what's meant only for a model" do
    assert relay("Error: offline") == "That didn't work: offline"

    work = %{"node" => "box", "session_id" => "ns_1", "title" => "check disks"}

    assert relay(Report.still_running(work)) ==
             "box is on it. I'll pass on its report when it's done."

    assert relay(Report.tool_answer(work, %{"answer" => "81% full"})) ==
             "box finished:\n\n81% full"
  end

  test "says how a node's report went, without repeating it" do
    work = %{"node" => "box", "session_id" => "ns_1", "title" => "check disks"}
    finished = Report.node_report(work, %{"answer" => "81% full"})
    failed = Report.node_report(work, %{"failure" => "went offline"})

    assert Message.text_of(ask(finished)) == "box finished. Its report is above."
    assert Message.text_of(ask(failed)) == "box didn't finish. The report above says why."
  end

  defp relay(text),
    do: Message.text_of(MockScript.respond(%{messages: [Message.tool_result("c1", text)]}))

  test "answers anything else with its help" do
    assert Message.text_of(ask("hello")) =~ "I'm Blip, on the scripted model"

    assert Message.text_of(MockScript.respond(%{messages: []})) =~
             "I'm Blip, on the scripted model"
  end
end
