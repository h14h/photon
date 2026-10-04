defmodule Photon.Assistant.PromptTest do
  @moduledoc "The assistant's system prompt and model settings."

  use Photon.Case, async: true

  @now ~U[2026-10-03 14:37:00Z]

  test "carries the memory, or says it's empty" do
    assert Prompt.system_prompt(settings(), "- the NAS is mp1", @now) =~
             "## Memory\n\n- the NAS is mp1\n"

    assert Prompt.system_prompt(settings(), "", @now) =~ "## Memory\n\n(empty)\n"
  end

  test "names the time to the hour, so it stays the same between requests" do
    prompt = Prompt.system_prompt(settings(), "", @now)

    assert prompt =~ "It's about 14:00 UTC on Saturday, October 3, 2026."
    assert prompt == Prompt.system_prompt(settings(), "", ~U[2026-10-03 14:59:59Z])
  end

  test "adds the user's time zone and standing instructions when set" do
    plain = Prompt.system_prompt(settings(), "", @now)
    refute plain =~ "time zone"
    refute plain =~ "The user's instructions"

    prompt =
      Prompt.system_prompt(
        settings(%{"timezone" => "America/Chicago", "instructions" => "  Prefer mp1.  "}),
        "",
        @now
      )

    assert prompt =~ "The user's time zone is America/Chicago; give times in it."
    assert String.ends_with?(prompt, "## The user's instructions\n\nPrefer mp1.")
  end

  test "asks for the reasoning effort only when one is set" do
    assert Prompt.reasoning(settings()) == nil
    assert Prompt.reasoning(settings(%{"reasoning" => "high"})) == "high"
  end

  test "opens with Blip's voice, in the owner's name when it's set" do
    prompt = Prompt.system_prompt(settings(), "", @now)
    assert String.starts_with?(prompt, "You are Blip, the assistant in the user's Photon hub.")
    assert prompt =~ "You hand work to the user's machines"
    assert prompt =~ "## How you work"
    refute prompt =~ "The user's name is"

    named = Prompt.system_prompt(settings(%{"user_name" => " Henry "}), "", @now)
    assert String.starts_with?(named, "You are Blip, the assistant in Henry's Photon hub.")
    assert named =~ "You hand work to Henry's machines"
    assert named =~ "The user's name is Henry."
  end
end
