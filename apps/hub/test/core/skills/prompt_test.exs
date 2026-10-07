defmodule Photon.Skills.PromptTest do
  @moduledoc "What agents see of skills (section 2.6 of the step 3 plan)."

  use Photon.Case, async: true

  alias Photon.Skills.Prompt

  @pdf %{
    id: "sk_pdf",
    name: "pdf-forms",
    version: 2,
    description: "Fill in PDF forms.\n  Use when the user asks to fill   or flatten one.",
    instructions: "# PDF forms\n\nFill each field.",
    files_left_out: []
  }

  @notes %{
    id: "sk_notes",
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

    test "lists each skill on a line, in the order given, escaped, on one line, with its ID and version" do
      section = Prompt.section([@pdf, @notes])

      assert String.starts_with?(section, "## Skills\n\nSkills are instructions for particular")
      assert section =~ "load it with load_skill before you start, and follow it."
      assert section =~ "it was turned off or deleted: stop following it."
      assert section =~ "If a skill's id or version here differs from the one you loaded"
      assert section =~ "load it again before you use it."

      assert String.ends_with?(
               section,
               """
               <available_skills>
               <skill><name>pdf-forms</name><version>2</version><id>sk_pdf</id><description>Fill in PDF forms. Use when the user asks to fill or flatten one.</description></skill>
               <skill><name>release-notes</name><version>1</version><id>sk_notes</id><description>Write &lt;release&gt; notes &amp; &#34;changelogs&#34; for the team&#39;s repos.</description></skill>
               </available_skills>\
               """
             )
    end
  end

  test "tells apart a skill deleted and another under its name, both at version 1" do
    first = Prompt.section([%{@notes | id: "sk_first"}])
    second = Prompt.section([%{@notes | id: "sk_second"}])

    refute first == second
    assert second =~ "<version>1</version><id>sk_second</id>"
    assert Prompt.loaded(%{@notes | id: "sk_first"}) =~ ~s(id="sk_first" version="1")
  end

  describe "loaded/1" do
    test "wraps the instructions in a skill element naming the version, and nothing after" do
      assert Prompt.loaded(@pdf) ==
               """
               <skill name="pdf-forms" id="sk_pdf" version="2">
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

  describe "loaded/2" do
    test "with no machines is loaded/1" do
      assert Prompt.loaded(@pdf, []) == Prompt.loaded(@pdf)
    end

    test "names the machine in the element and says to follow it there" do
      assert Prompt.loaded(@pdf, ["mm1"]) ==
               """
               <skill name="pdf-forms" id="sk_pdf" version="2" machines="mm1">
               # PDF forms

               Fill each field.
               </skill>
               This skill is turned on for mm1: follow it when you work on mm1.\
               """
    end

    test "names several machines" do
      [header | _rest] = String.split(Prompt.loaded(@pdf, ["mm1", "mp1"]), "\n")
      assert header == ~s(<skill name="pdf-forms" id="sk_pdf" version="2" machines="mm1 mp1">)

      assert String.ends_with?(
               Prompt.loaded(@pdf, ["mm1", "mp1"]),
               "</skill>\nThis skill is turned on for mm1 and mp1: " <>
                 "follow it when you work on those machines."
             )

      assert String.ends_with?(
               Prompt.loaded(@pdf, ["local", "mm1", "mp1"]),
               "This skill is turned on for local, mm1 and mp1: " <>
                 "follow it when you work on those machines."
             )
    end

    test "puts the machine line before the files install left out" do
      skill = %{@pdf | files_left_out: ["scripts/fill.py"]}
      [_skill, lines] = String.split(Prompt.loaded(skill, ["mm1"]), "</skill>\n")

      assert [
               "This skill is turned on for mm1: follow it when you work on mm1.",
               "This skill was installed without its other files (scripts/fill.py)." <> _
             ] = String.split(lines, "\n")
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

  describe "not_loaded/3" do
    test "with no machine skills is not_loaded/2" do
      assert Prompt.not_loaded("pdf-form", ["pdf-forms"], []) ==
               Prompt.not_loaded("pdf-form", ["pdf-forms"])

      assert Prompt.not_loaded("pdf-form", [], []) == "No skills are turned on here."
    end

    test "names the skills on here and each machine's" do
      assert Prompt.not_loaded("ios", ["pdf-forms", "release-notes"], [
               {"mm1", ["ios-simulators", "xcode"]},
               {"mp1", ["hosting-private-apps"]}
             ]) ==
               "There's no skill called ios turned on here or for a machine. " <>
                 "Turned on here: pdf-forms, release-notes. " <>
                 "For machines: mm1 has ios-simulators, xcode; mp1 has hosting-private-apps."
    end

    test "names only the machines' when none are on here" do
      assert Prompt.not_loaded("ios", [], [{"mm1", ["ios-simulators"]}]) ==
               "There's no skill called ios turned on here or for a machine. " <>
                 "For machines: mm1 has ios-simulators."
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
