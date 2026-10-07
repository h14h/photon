defmodule Photon.Threads.MockScriptTest do
  @moduledoc "A thread's scripted model: its fixed phrasings (section 3.5)."

  use Photon.Case, async: true

  alias Photon.Skills.Prompt, as: SkillsPrompt
  alias Photon.Threads.MockScript

  defp ask(text), do: MockScript.respond(%{messages: [Message.user(text)]})

  defp calls(message), do: Enum.map(Message.tool_calls(message), &{&1["name"], args(&1)})

  defp args(call) do
    {:ok, args} = Message.arguments(call)
    args
  end

  test "understands Blip's machine phrasings" do
    assert calls(ask("machines")) == [{"list_machines", %{}}]

    assert calls(ask("on box: $ ls -la")) ==
             [{"shell", %{"machine" => "box", "command" => "ls -la"}}]

    assert calls(ask("on box: look at shot.png")) ==
             [{"view_image", %{"machine" => "box", "path" => "shot.png"}}]
  end

  test "lists the context files" do
    assert calls(ask("files")) == [{"list_context_files", %{}}]
    assert calls(ask("list files")) == [{"list_context_files", %{}}]
  end

  test "reads a context file" do
    assert calls(ask("read notes.md")) == [{"read_context_file", %{"name" => "notes.md"}}]
  end

  test "writes a context file, over several lines" do
    assert calls(ask("write notes.md: hello")) ==
             [{"write_context_file", %{"name" => "notes.md", "content" => "hello"}}]

    assert calls(ask("write plan.md: # Plan\n\n- water zone 1\n- check zone 2")) ==
             [
               {"write_context_file",
                %{"name" => "plan.md", "content" => "# Plan\n\n- water zone 1\n- check zone 2"}}
             ]
  end

  test "edits a context file" do
    assert calls(ask("edit notes.md: hello => bye")) ==
             [
               {"edit_context_file",
                %{"name" => "notes.md", "old_text" => "hello", "new_text" => "bye"}}
             ]

    assert calls(ask("edit notes.md: zone 2 =>")) ==
             [
               {"edit_context_file",
                %{"name" => "notes.md", "old_text" => "zone 2", "new_text" => ""}}
             ]
  end

  test "drops a leading [Scheduled], so a schedule's prompt runs as typed" do
    assert calls(ask("[Scheduled] on box: $ ls")) ==
             [{"shell", %{"machine" => "box", "command" => "ls"}}]

    assert calls(ask("[Scheduled] files")) == [{"list_context_files", %{}}]
    assert Message.text_of(ask("[Scheduled] tidy the shed")) =~ "scripted model"
  end

  test "reads the last text part of the message" do
    message = Message.user([Message.text("[Looking at the project]"), Message.text("files")])
    assert calls(MockScript.respond(%{messages: [message]})) == [{"list_context_files", %{}}]
  end

  test "relays a tool's result, and an error" do
    assert relay("Wrote notes.md (5 characters).") == "Wrote notes.md (5 characters)."

    assert relay("Error: old_text wasn't found in notes.md.") ==
             "That didn't work: old_text wasn't found in notes.md."
  end

  defp relay(content),
    do: Message.text_of(MockScript.respond(%{messages: [Message.tool_result("c1", content)]}))

  test "answers anything else with its help" do
    help = Message.text_of(ask("tidy the shed"))
    assert help =~ "scripted model"
    assert help =~ "`write <name>: <text>`"
    assert help =~ "Sign in with ChatGPT"
    assert calls(ask("tidy the shed")) == []
    assert Message.text_of(MockScript.respond(%{messages: []})) =~ "scripted model"
  end

  describe "skills" do
    @system "You are an agent.\n\n" <>
              SkillsPrompt.section([
                %{id: "sk_pdf", name: "pdf-forms", version: 2, description: "Fill in PDF forms."}
              ])

    test "skills says what the prompt lists, and load skill loads one" do
      listed = MockScript.respond(%{system: @system, messages: [Message.user("skills")]})
      assert calls(listed) == []
      assert Message.text_of(listed) == "Skills turned on here: pdf-forms (version 2)."

      assert Message.text_of(ask("skills")) == "No skills are turned on here."
      assert calls(ask("load skill pdf-forms")) == [{"load_skill", %{"name" => "pdf-forms"}}]
    end

    test "relays a loaded skill, and its help lists the phrasings" do
      loaded = ~s(<skill name="pdf-forms" id="sk_pdf" version="2">\nFill it.\n</skill>)
      assert relay(loaded) == "```\n" <> loaded <> "\n```"

      help = Message.text_of(ask("tidy the shed"))
      assert help =~ "`skills`"
      assert help =~ "`load skill <name>`"
    end
  end

  describe "ask blip" do
    test "asks Blip the question, trimmed" do
      asked = ask("ask blip:  which deploy branch? ")
      assert calls(asked) == [{"ask_blip", %{"question" => "which deploy branch?"}}]
      assert Message.text_of(asked) == "Asking Blip."

      assert calls(ask("[Scheduled] ask blip: is the gate locked? (prose)")) ==
               [{"ask_blip", %{"question" => "is the gate locked? (prose)"}}]
    end

    test "an empty question is only help" do
      assert calls(ask("ask blip:")) == []
    end

    test "relays Blip's answer, and the user's" do
      assert relay("Blip answered: staging") == "Blip answered: staging"

      # Prose, a paragraph a line, not a code block that runs off the page.
      assert relay("Blip asked the user: Which colour?\nThey answered: Sage green.") ==
               "Blip asked the user: Which colour?\n\nThey answered: Sage green."

      assert relay("Error: This question was withdrawn.") ==
               "That didn't work: This question was withdrawn."
    end

    test "the help lists it" do
      assert Message.text_of(ask("tidy the shed")) =~ "`ask blip: <question>`"
    end
  end

  describe "run endings" do
    test "ask me: answers with the question, so the run ends asking" do
      asked = ask("ask me: which zone should I water first?")
      assert calls(asked) == []
      assert Message.text_of(asked) == "which zone should I water first?"

      assert Message.text_of(ask("ask me:  should I order a valve ")) ==
               "should I order a valve?"
    end

    test "fail: fails the model request with the reason" do
      assert ask("fail: the pump is unplugged") == {:error, "the pump is unplugged"}
      assert ask("[Scheduled] fail: no water") == {:error, "no water"}
    end

    test "the help lists both" do
      help = Message.text_of(ask("tidy the shed"))
      assert help =~ "`ask me: <question>`"
      assert help =~ "`fail: <reason>`"
    end
  end
end
