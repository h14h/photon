defmodule Photon.Assistant.MockScriptTest do
  @moduledoc "The mock assistant model's fixed phrasings."

  use Photon.Case, async: true

  alias Photon.Assistant.MockScript
  alias Photon.Skills.Prompt, as: SkillsPrompt

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

  test "relays what the schedule tools say, with their sc_ IDs" do
    scheduled = "Scheduled sc_4f2a: first at 2026-10-08 09:00 UTC, then every 1440 minutes."
    assert relay(scheduled) == scheduled
    assert relay("Cancelled sc_4f2a.") == "Cancelled sc_4f2a."

    assert relay("Error: There is no schedule sc_nope.") ==
             "That didn't work: There is no schedule sc_nope."

    listed =
      ~s(Now: 2026-10-07 08:12 UTC.\n- sc_4f2a: next 2026-10-08 09:00 UTC, every 1440 min: "machines")

    assert relay(listed) =~ ~s(- sc_4f2a: next 2026-10-08 09:00 UTC, every 1440 min: "machines")
  end

  defp relay(content),
    do: Message.text_of(MockScript.respond(%{messages: [Message.tool_result("c1", content)]}))

  test "reads the last text part, what the user typed, past a page's note" do
    note =
      ~s([Looking at the project "Garden", folder "garden" in each machine's workspace]\nPurpose: water)

    message = Message.user([Message.text(note), Message.text("machines")])

    assert calls(MockScript.respond(%{messages: [message]})) == [{"list_machines", %{}}]
  end

  test "here says the first line of the page's note, or that it doesn't know the page" do
    note =
      ~s([Looking at notes.md in the project "Garden", folder "garden" in each machine's workspace]\nPurpose: water)

    message = Message.user([Message.text(note), Message.text("here")])

    assert Message.text_of(MockScript.respond(%{messages: [message]})) ==
             ~s([Looking at notes.md in the project "Garden", folder "garden" in each machine's workspace])

    assert Message.text_of(ask("here")) == "I don't know which page you're on."
    assert Message.text_of(ask("Here?")) == "I don't know which page you're on."
  end

  test "answers anything else with its help" do
    assert Message.text_of(ask("hello")) =~ "I'm Blip, on the scripted model"

    assert Message.text_of(MockScript.respond(%{messages: []})) =~
             "I'm Blip, on the scripted model"
  end

  describe "skills" do
    @system "You are an agent.\n\n" <>
              SkillsPrompt.section([
                %{name: "pdf-forms", version: 2, description: "Fill in PDF forms."}
              ])

    test "skills says what the prompt lists, and load skill loads one" do
      listed = MockScript.respond(%{system: @system, messages: [Message.user("skills")]})
      assert calls(listed) == []
      assert Message.text_of(listed) == "Skills turned on here: pdf-forms (version 2)."

      assert Message.text_of(ask("skills")) == "No skills are turned on here."
      assert calls(ask("load skill pdf-forms")) == [{"load_skill", %{"name" => "pdf-forms"}}]
    end

    test "relays a loaded skill, and its help lists the phrasings" do
      loaded = ~s(<skill name="pdf-forms" version="2">\nFill it.\n</skill>)
      assert relay(loaded) == "```\n" <> loaded <> "\n```"

      help = Message.text_of(ask("tidy the shed"))
      assert help =~ "`skills`"
      assert help =~ "`load skill <name>`"
    end
  end
end
