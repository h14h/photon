defmodule Photon.Assistant.MockScriptTest do
  @moduledoc "The mock assistant model's fixed phrasings."

  use Photon.Case, async: true

  alias Photon.Assistant.MockScript

  defp ask(text), do: MockScript.respond(%{messages: [Message.user(text)]})

  defp calls(message), do: Enum.map(Message.tool_calls(message), &{&1["name"], args(&1)})

  defp args(call) do
    {:ok, args} = Message.arguments(call)
    args
  end

  test "lists machines" do
    assert calls(ask("machines")) == [{"list_machines", %{}}]
    assert calls(ask("list machines")) == [{"list_machines", %{}}]
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

  test "answers a task for a machine that isn't a command or an image with its help" do
    assert calls(ask("on mp1: check the backups")) == []
    assert Message.text_of(ask("on mp1: check the backups")) =~ "on the scripted model"
  end

  test "remembers, and schedules" do
    assert calls(ask("remember the NAS is mp1")) ==
             [{"update_memory", %{"action" => "add", "text" => "the NAS is mp1"}}]

    assert calls(ask("in 2 minutes: machines")) ==
             [{"schedule", %{"prompt" => "machines", "in_minutes" => 2}}]

    assert calls(ask("every 30 minutes: machines")) ==
             [{"schedule", %{"prompt" => "machines", "every_minutes" => 30}}]

    assert calls(ask("schedules")) == [{"list_schedules", %{}}]
  end

  test "acts on a scheduled prompt as if the user asked" do
    assert calls(ask("[Scheduled] machines")) == [{"list_machines", %{}}]
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
