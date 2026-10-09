defmodule Photon.SkillToolsTest do
  @moduledoc """
  How agents see and load skills, through the scripted models: `skills` says
  what the profile's prompt listed, and `load skill <name>` calls
  `load_skill`. The prompt's and the loaded text's exact words are covered
  in `test/core/skills/prompt_test.exs`.

  A skill turned on for a machine reaches Blip and every thread whatever
  their own sets hold: the `machine skills` cases.
  """

  use Photon.DataCase, async: false

  @moduletag :durable

  alias Photon.{Assistant, NodeKeys, Projects, Skills, Threads}
  alias Photon.Durable.Context
  alias Photon.Skills.Prompt, as: SkillsPrompt
  alias PhotonCore.Message

  setup do
    {:ok, project} =
      Projects.create(%{"purpose" => "Keep the garden watered.", "name" => "Garden"})

    {:ok, skill} =
      Skills.create(%{
        "name" => "pdf-forms",
        "description" => "Fill in PDF forms.",
        "instructions" => "# PDF forms\n\nFill each field."
      })

    :ok = Skills.enable(skill.id, {:project, project.id})

    {:ok, thread} = Threads.start(project.id, "hello")
    :ok = Threads.subscribe(thread.id)
    await_entry(thread.id, &(&1.kind == "assistant"))

    %{project: project, skill: skill, thread: thread.id}
  end

  # Sends `text` to the thread and waits for its run to settle.
  defp ask(thread, text) do
    {:ok, submission} = Threads.send(thread, text)
    _settled = await_settled(thread, submission.id)
    :ok
  end

  # Sends `text` to Blip, whose conversation the test subscribed to, and
  # waits for the run to settle.
  defp ask_blip(blip, text) do
    {:ok, submission} = Assistant.send(text)
    _settled = await_settled(blip, submission.id)
    :ok
  end

  defp last(conversation, kind),
    do: conversation |> Durable.entries() |> Enum.filter(&(&1.kind == kind)) |> List.last()

  defp answer(conversation), do: Message.text_of(last(conversation, "assistant").data["message"])

  defp result_text(conversation),
    do: Message.text_of(last(conversation, "tool_result").data["message"])

  test "a thread lists the project's skills and loads one", %{thread: thread, skill: skill} do
    :ok = ask(thread, "skills")
    assert answer(thread) == "Skills turned on here: pdf-forms (version 1)."

    :ok = ask(thread, "load skill pdf-forms")
    result = last(thread, "tool_result")

    assert Message.text_of(result.data["message"]) == SkillsPrompt.loaded(skill)
    assert SkillsPrompt.loaded(skill) =~ "# PDF forms\n\nFill each field."

    assert result.data["details"] == %{
             "skill" => "pdf-forms",
             "version" => 1,
             "full_output" => ~s[Load it again with load_skill("pdf-forms") to read all of it]
           }
  end

  test "a skill installed without its files says so when it loads", %{
    project: project,
    thread: thread
  } do
    {:ok, installed} =
      Skills.install(
        %{
          "name" => "fill-forms",
          "description" => "Fill forms with the script.",
          "instructions" => "Run `scripts/fill.py` on the form."
        },
        %{origin: "pasted", files_left_out: ["scripts/fill.py", "reference.md"]}
      )

    :ok = Skills.enable(installed.id, {:project, project.id})

    :ok = ask(thread, "load skill fill-forms")

    assert result_text(thread) =~
             "</skill>\nThis skill was installed without its other files " <>
               "(scripts/fill.py, reference.md). They aren't on any machine"
  end

  test "once turned off, a skill can't be loaded and isn't listed", %{
    project: project,
    skill: skill,
    thread: thread
  } do
    :ok = Skills.disable(skill.id, {:project, project.id})

    :ok = ask(thread, "load skill pdf-forms")
    assert result_text(thread) == "Error: No skills are turned on here."

    :ok = ask(thread, "skills")
    assert answer(thread) == "No skills are turned on here."
  end

  test "a name that isn't on gets the names that are", %{thread: thread} do
    :ok = ask(thread, "load skill pdf-form")

    assert result_text(thread) ==
             "Error: There's no skill called pdf-form turned on here. Turned on here: pdf-forms."

    :ok = ask(thread, "load skill PDF-Forms")
    assert result_text(thread) =~ ~r/<skill name="pdf-forms" id="sk_\w+" version="1">/
  end

  test "Blip can't load a skill that is on only for a project, and loads its own", %{
    skill: skill
  } do
    blip = Assistant.conversation_id()
    :ok = Assistant.subscribe(blip)

    :ok = ask_blip(blip, "load skill pdf-forms")
    assert result_text(blip) == "Error: No skills are turned on here."

    :ok = ask_blip(blip, "skills")
    assert answer(blip) == "No skills are turned on here."

    :ok = Skills.enable(skill.id, :blip)

    :ok = ask_blip(blip, "load skill pdf-forms")
    assert result_text(blip) == SkillsPrompt.loaded(skill)

    :ok = ask_blip(blip, "skills")
    assert answer(blip) == "Skills turned on here: pdf-forms (version 1)."
  end

  test "each profile's prompt lists the skills on for its own scope only", %{
    project: project,
    skill: skill,
    thread: thread
  } do
    {:ok, other} = Projects.create(%{"purpose" => "Fix the shed.", "name" => "Shed"})
    {:ok, other_thread} = Threads.start(other.id, "hello")
    :ok = Threads.subscribe(other_thread.id)
    await_entry(other_thread.id, &(&1.kind == "assistant"))

    {:ok, blip_only} =
      Skills.create(%{
        "name" => "morning-review",
        "description" => "Review the morning.",
        "instructions" => "Check the disks."
      })

    :ok = Skills.enable(blip_only.id, :blip)

    garden = Threads.system_prompt(Durable.conversation(thread))
    shed = Threads.system_prompt(Durable.conversation(other_thread.id))
    blip = Assistant.system_prompt(nil)

    assert garden =~ "<name>pdf-forms</name>"
    refute garden =~ "morning-review"
    refute shed =~ "## Skills"
    assert blip =~ "<name>morning-review</name>"
    refute blip =~ "pdf-forms"

    # A change applies to the next request.
    :ok = Skills.disable(skill.id, {:project, project.id})
    refute Threads.system_prompt(Durable.conversation(thread)) =~ "## Skills"
  end

  test "a long skill loaded in an earlier run is cut in the next run's input, with the hint", %{
    project: project,
    thread: thread
  } do
    {:ok, long} =
      Skills.create(%{
        "name" => "long-one",
        "description" => "A long skill.",
        "instructions" => String.duplicate("Step by step. ", 400)
      })

    :ok = Skills.enable(long.id, {:project, project.id})

    :ok = ask(thread, "load skill long-one")
    :ok = ask(thread, "skills")

    [loaded] =
      for %{"role" => "tool"} = message <- Context.messages(Durable.entries(thread)),
          do: Message.text_of(message)

    assert loaded =~
             ~r/characters of this older result left out\. Load it again with load_skill\("long-one"\) to read all of it\.\.\./

    assert String.starts_with?(loaded, ~s(<skill name="long-one" id="#{long.id}" version="1">))
  end

  describe "machine skills" do
    setup do
      {:ok, _key} = NodeKeys.issue("mm1")

      {:ok, ios} =
        Skills.create(%{
          "name" => "ios-simulators",
          "description" => "Run and drive iOS simulators on this Mac.",
          "instructions" => "Boot one with `xcrun simctl boot`."
        })

      :ok = Skills.enable(ios.id, {:machine, "mm1"})

      {:ok, shed} = Projects.create(%{"purpose" => "Fix the shed.", "name" => "Shed"})
      {:ok, shed_thread} = Threads.start(shed.id, "hello")
      :ok = Threads.subscribe(shed_thread.id)
      await_entry(shed_thread.id, &(&1.kind == "assistant"))

      %{ios: ios, shed_thread: shed_thread.id}
    end

    test "a thread in a project with no skills lists and loads a machine's", %{
      ios: ios,
      shed_thread: thread
    } do
      :ok = ask(thread, "skills")

      assert answer(thread) ==
               "No skills are turned on here. For machines: mm1: ios-simulators (version 1)."

      :ok = ask(thread, "load skill ios-simulators")
      result = last(thread, "tool_result")

      assert Message.text_of(result.data["message"]) == SkillsPrompt.loaded(ios, ["mm1"])

      assert Message.text_of(result.data["message"]) =~
               "</skill>\nThis skill is turned on for mm1: follow it when you work on mm1."

      assert result.data["details"]["machines"] == ["mm1"]
    end

    test "a thread with its own skills gets the machine's too", %{thread: thread} do
      :ok = ask(thread, "skills")

      assert answer(thread) ==
               "Skills turned on here: pdf-forms (version 1). " <>
                 "For machines: mm1: ios-simulators (version 1)."
    end

    test "Blip lists and loads a machine's skill", %{ios: ios} do
      blip = Assistant.conversation_id()
      :ok = Assistant.subscribe(blip)

      :ok = ask_blip(blip, "skills")

      assert answer(blip) ==
               "No skills are turned on here. For machines: mm1: ios-simulators (version 1)."

      :ok = ask_blip(blip, "load skill ios-simulators")
      assert result_text(blip) == SkillsPrompt.loaded(ios, ["mm1"])
    end

    test "turned off between two messages, it is no longer listed and won't load", %{
      ios: ios,
      shed_thread: thread
    } do
      :ok = ask(thread, "skills")
      assert answer(thread) =~ "mm1: ios-simulators"

      :ok = Skills.disable(ios.id, {:machine, "mm1"})

      :ok = ask(thread, "skills")
      assert answer(thread) == "No skills are turned on here."

      :ok = ask(thread, "load skill ios-simulators")
      assert result_text(thread) == "Error: No skills are turned on here."
    end

    test "every prompt lists it under its machine, and a removed machine's group goes", %{
      shed_thread: thread
    } do
      blip = Assistant.system_prompt(nil)
      shed = Threads.system_prompt(Durable.conversation(thread))

      for prompt <- [blip, shed] do
        assert prompt =~ ~s(<machine name="mm1">\n<skill><name>ios-simulators</name>)
      end

      :ok = NodeKeys.revoke("mm1")
      refute Threads.system_prompt(Durable.conversation(thread)) =~ "## Skills"
      refute Assistant.system_prompt(nil) =~ "ios-simulators"
    end
  end
end
