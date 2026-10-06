defmodule Photon.Skills.PromptTest do
  @moduledoc "What agents see of skills (section 2.6 of the step 3 plan)."

  use Photon.Case, async: true

  alias Photon.Skills.Prompt

  @pdf %{
    name: "pdf-forms",
    version: 2,
    description: "Fill in PDF forms.\n  Use when the user asks to fill   or flatten one.",
    instructions: "# PDF forms\n\nFill each field.",
    files_left_out: []
  }

  @notes %{
    name: "release-notes",
    version: 1,
    description: ~s(Write <release> notes & "changelogs" for the team's repos.),
    instructions: "Write them.",
    files_left_out: []
  }

  describe "section/1" do
    test "is nil with no skills, so the prompt has no trace of them" do
      assert Prompt.section([]) == nil
    end

    test "lists each skill on a line, in the order given, escaped, on one line, with its version" do
      section = Prompt.section([@pdf, @notes])

      assert String.starts_with?(section, "## Skills\n\nSkills are instructions for particular")
      assert section =~ "load it with load_skill before you start, and follow it."
      assert section =~ "it was turned off or deleted: stop following it."
      assert section =~ "load it again before you use it."

      assert String.ends_with?(
               section,
               """
               <available_skills>
               <skill><name>pdf-forms</name><version>2</version><description>Fill in PDF forms. Use when the user asks to fill or flatten one.</description></skill>
               <skill><name>release-notes</name><version>1</version><description>Write &lt;release&gt; notes &amp; &#34;changelogs&#34; for the team&#39;s repos.</description></skill>
               </available_skills>\
               """
             )
    end
  end

  describe "loaded/1" do
    test "wraps the instructions in a skill element naming the version, and nothing after" do
      assert Prompt.loaded(@pdf) ==
               """
               <skill name="pdf-forms" version="2">
               # PDF forms

               Fill each field.
               </skill>\
               """
    end

    test "names the files install left out, and says not to look for them" do
      loaded = Prompt.loaded(%{@pdf | files_left_out: ["scripts/fill.py", "reference.md"]})
      [skill, line] = String.split(loaded, "</skill>\n")

      assert skill == String.trim_trailing(Prompt.loaded(@pdf), "</skill>")

      assert line ==
               "This skill was installed without its other files (scripts/fill.py, reference.md). " <>
                 "They aren't on any machine: don't look for them or run them. Do what you can " <>
                 "from the instructions, and tell the user if the task needs a missing file."
    end
  end

  describe "not_loaded/2" do
    test "names the skills that are on" do
      assert Prompt.not_loaded("pdf-form", ["pdf-forms", "release-notes"]) ==
               "There's no skill called pdf-form turned on here. " <>
                 "Turned on here: pdf-forms, release-notes."
    end

    test "says when none are" do
      assert Prompt.not_loaded("pdf-form", []) == "No skills are turned on here."
    end
  end

  test "the tool's name, description, parameters and the hint for a cut result" do
    assert Prompt.tool_name() == "load_skill"
    assert Prompt.tool_description() =~ "Load a skill's instructions into this conversation."
    assert Prompt.tool_parameters()["required"] == ["name"]

    assert Prompt.full_output_hint("pdf-forms") ==
             ~s[Load it again with load_skill("pdf-forms") to read all of it]
  end
end
