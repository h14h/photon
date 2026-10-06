defmodule Photon.Assistant.MockScriptTest do
  @moduledoc "The mock assistant model's fixed phrasings."

  use Photon.Case, async: true

  alias Photon.Assistant.{MockScript, Page, Report}

  defp ask(text), do: MockScript.respond(%{messages: [Message.user(text)]})

  defp calls(message), do: Enum.map(Message.tool_calls(message), &{&1["name"], args(&1)})

  defp args(call) do
    {:ok, args} = Message.arguments(call)
    args
  end

  test "lists machines, and nodes" do
    assert calls(ask("machines")) == [{"list_machines", %{}}]
    assert calls(ask("list machines")) == [{"list_machines", %{}}]
    assert calls(ask("nodes")) == [{"list_nodes", %{}}]
  end

  test "reads a message sent from a page as it was typed" do
    page = %{"session_id" => "ns_1", "node" => "mp1", "title" => "Backup"}
    assert calls(ask(Page.note("nodes", page))) == [{"list_nodes", %{}}]
  end

  test "runs a command on a machine" do
    assert calls(ask("on mp1: $ uptime")) ==
             [{"shell", %{"machine" => "mp1", "command" => "uptime"}}]

    assert calls(ask("on local: $ sleep 1; echo done")) ==
             [{"shell", %{"machine" => "local", "command" => "sleep 1; echo done"}}]
  end

  test "looks at an image on a machine" do
    assert calls(ask("on mm1: look at /tmp/shot.png")) ==
             [{"view_image", %{"machine" => "mm1", "path" => "/tmp/shot.png"}}]
  end

  test "hands anything else to a node's agent" do
    assert calls(ask("on mp1: check the backups")) ==
             [
               {"run_on_node",
                %{"node" => "mp1", "task" => "check the backups", "wait_seconds" => 5}}
             ]
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

  test "relays a machine tool's result, and says an image is here" do
    assert relay("hello") == "hello"
    assert relay("Error: mm1 has been offline") == "That didn't work: mm1 has been offline"

    image = [
      Message.image("image/png", "iVBORw0KGgo="),
      Message.text("1x1 image/png, /tmp/dot.png on local")
    ]

    assert relay(image) == "Here it is.\n\n1x1 image/png, /tmp/dot.png on local"
  end

  defp relay(content),
    do: Message.text_of(MockScript.respond(%{messages: [Message.tool_result("c1", content)]}))

  test "answers anything else with its help" do
    assert Message.text_of(ask("hello")) =~ "I'm Blip, on the scripted model"

    assert Message.text_of(MockScript.respond(%{messages: []})) =~
             "I'm Blip, on the scripted model"
  end
end
