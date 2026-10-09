defmodule Photon.Skills.MockPhrasesTest do
  @moduledoc "The skill phrasings the scripted models share."

  use Photon.Case, async: true

  alias Photon.Skills.MockPhrases
  alias Photon.Skills.Prompt, as: SkillsPrompt

  @pdf %{id: "sk_pdf", name: "pdf-forms", version: 2, description: "Fill in PDF forms."}
  @notes %{id: "sk_notes", name: "release-notes", version: 1, description: "Write release notes."}
  @hosting %{id: "sk_host", name: "hosting-private-apps", version: 1, description: "Serve it."}
  @ios %{id: "sk_ios", name: "ios-simulators", version: 3, description: "Run simulators."}

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
        SkillsPrompt.section(%{own: [@pdf, @notes], machines: []})

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

  test "skills names each machine's skills after the agent's own" do
    system =
      "You are an agent.\n\n" <>
        SkillsPrompt.section(%{
          own: [@pdf],
          machines: [{"local", [@hosting]}, {"mm1", [@ios, @notes]}]
        })

    assert Message.text_of(reply("skills", system)) ==
             "Skills turned on here: pdf-forms (version 2). For machines: " <>
               "local: hosting-private-apps (version 1); " <>
               "mm1: ios-simulators (version 3), release-notes (version 1)."
  end

  test "skills with only machine skills says none are on here, then names them" do
    system = SkillsPrompt.section(%{own: [], machines: [{"local", [@hosting]}]})

    assert Message.text_of(reply("skills", system)) ==
             "No skills are turned on here. For machines: local: hosting-private-apps (version 1)."
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
