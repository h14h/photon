defmodule Photon.Skills.MockPhrasesTest do
  @moduledoc "The skill phrasings the scripted models share (section 4 of the step 3 plan)."

  use Photon.Case, async: true

  alias Photon.Skills.MockPhrases
  alias Photon.Skills.Prompt, as: SkillsPrompt

  # The reply of the first phrasing `text` matches, for a request whose
  # system prompt is `system`.
  defp reply(text, system \\ "") do
    %{system: system}
    |> MockPhrases.phrasings()
    |> Enum.find_value(fn {pattern, reply} ->
      case Regex.run(pattern, text, capture: :all_but_first) do
        nil -> nil
        captures -> reply.(captures)
      end
    end)
  end

  defp calls(message),
    do:
      Enum.map(Message.tool_calls(message), fn call ->
        {:ok, args} = Message.arguments(call)
        {call["name"], args}
      end)

  test "skills lists what the system prompt lists, with versions, without a tool call" do
    system =
      "You are an agent.\n\n" <>
        SkillsPrompt.section([
          %{name: "pdf-forms", version: 2, description: "Fill in PDF forms."},
          %{name: "release-notes", version: 1, description: "Write release notes."}
        ])

    for text <- ["skills", "list skills"] do
      message = reply(text, system)
      assert calls(message) == []

      assert Message.text_of(message) ==
               "Skills turned on here: pdf-forms (version 2), release-notes (version 1)."
    end
  end

  test "skills says none are on when the prompt lists none" do
    assert Message.text_of(reply("skills", "You are an agent.")) ==
             "No skills are turned on here."

    assert Message.text_of(reply("skills")) == "No skills are turned on here."
  end

  test "load skill calls load_skill with the name" do
    message = reply("load skill pdf-forms")
    assert calls(message) == [{"load_skill", %{"name" => "pdf-forms"}}]
    assert Message.text_of(message) == "Loading the pdf-forms skill."
  end

  test "anything else matches neither" do
    assert reply("load skill") == nil
    assert reply("skills please") == nil
  end
end
