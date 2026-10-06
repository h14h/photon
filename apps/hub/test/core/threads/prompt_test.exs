defmodule Photon.Threads.PromptTest do
  @moduledoc """
  A thread's system prompt (section 3.2). That nothing about the user gets
  in is checked on the profile in `test/boundary/threads_test.exs`, since
  this function never sees Settings.
  """

  use Photon.Case, async: true

  alias Photon.MachineTools.Guide
  alias Photon.Skills.Prompt, as: SkillsPrompt
  alias Photon.Threads.Prompt

  @project %{
    name: "Garden",
    slug: "garden",
    purpose: "Keep the garden's irrigation running through winter.\n\nIt has three zones."
  }

  @now ~U[2026-10-07 14:03:00Z]

  test "has the project's name and its purpose, verbatim" do
    prompt = Prompt.system_prompt(@project, @now, [])
    assert prompt =~ "Name: Garden"
    assert prompt =~ @project.purpose
  end

  test "names the project's folder with its slug as the working directory" do
    prompt = Prompt.system_prompt(@project, @now, [])

    assert prompt =~
             "Your working directory on every machine is the project's folder, `<workspace>/garden`"

    assert prompt =~ "made the first time a command runs there"
  end

  test "has the shell lines shared with Blip's prompt, for the project's folder" do
    assert Prompt.system_prompt(@project, @now, []) =~ "- " <> Guide.shell("the project's folder")
  end

  test "names the tools it has and none it doesn't" do
    prompt = Prompt.system_prompt(@project, @now, [])

    for tool <-
          ~w(shell view_image list_machines list_context_files read_context_file write_context_file edit_context_file),
        do: assert(prompt =~ tool)

    refute prompt =~ "schedule"
    refute prompt =~ "memory"
  end

  test "names the time to the hour, so it is the same all hour" do
    prompt = Prompt.system_prompt(@project, @now, [])
    assert prompt =~ "It's about 14:00 UTC on Wednesday, October 7, 2026."
    assert Prompt.system_prompt(@project, ~U[2026-10-07 14:59:59Z], []) == prompt
    refute Prompt.system_prompt(@project, ~U[2026-10-07 15:00:00Z], []) == prompt
  end

  describe "skills" do
    @skills [
      %{name: "pdf-forms", version: 2, description: "Fill in PDF forms."},
      %{name: "release-notes", version: 1, description: "Write release notes."}
    ]

    test "with none turned on there is no Skills section" do
      prompt = Prompt.system_prompt(@project, @now, [])
      refute prompt =~ "## Skills"
      refute prompt =~ "load_skill"
    end

    test "with two, the section sits between How you work and Now, and nothing else moves" do
      prompt = Prompt.system_prompt(@project, @now, @skills)
      section = SkillsPrompt.section(@skills)

      assert prompt =~
               "Use Markdown when it helps. Say the result first, then the detail.\n\n" <>
                 section <> "\n\n## Now\n"

      assert prompt =~ "<name>pdf-forms</name><version>2</version>"
      assert prompt =~ "<name>release-notes</name><version>1</version>"

      assert String.replace(prompt, section <> "\n\n", "") ==
               Prompt.system_prompt(@project, @now, [])
    end
  end
end
