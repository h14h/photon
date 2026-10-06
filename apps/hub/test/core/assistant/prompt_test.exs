defmodule Photon.Assistant.PromptTest do
  @moduledoc "The assistant's system prompt."

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

  test "searches the web itself rather than sending a machine" do
    assert Prompt.system_prompt(settings(), "", @now) =~ "You can search the web yourself"
  end

  test "runs work on machines itself, with no node agent to hand it to" do
    prompt = Prompt.system_prompt(settings(), "", @now)
    assert prompt =~ "You have shell and view_image on every machine"
    assert prompt =~ "Background children are killed when the command exits, nohup or not."
    assert prompt =~ "bash -c 'set -m; nohup CMD >CMD.log 2>&1 &'"
    assert prompt =~ "Use list_machines"
    refute prompt =~ "run_on_node"
    refute prompt =~ "node_session"
    refute prompt =~ "[Report from"
  end

  test "checks back on long work with a schedule rather than holding the conversation" do
    prompt = Prompt.system_prompt(settings(), "", @now)
    assert prompt =~ "A shell call holds the conversation until its command exits"
    assert prompt =~ ~S[nohup sh -c "CMD; echo \$? >CMD.exit" >CMD.log 2>&1 &]
    assert prompt =~ "use schedule with in_minutes to check the log and exit code later"
    assert prompt =~ "Promise to report back only when you've scheduled that check."
  end

  # Pins "How you work" word for word, so the shell lines that come from
  # `Photon.MachineTools.Guide` read exactly as they did when they were
  # written here.
  test "says how it works, word for word" do
    prompt = Prompt.system_prompt(settings(), "", @now)
    [_voice, rest] = String.split(prompt, "## How you work\n\n")
    [how, _rest] = String.split(rest, "\n\n## Memory")

    assert how ==
             ~S"""
             - The hub is always on, and you reach the user's machines through it.
             - Use Markdown when it helps.
             - You can search the web yourself, and open a page: for facts, docs, versions, prices, news, or a link the user gives you. Do that rather than sending a machine to look something up, and link where the answer came from.
             - You have shell and view_image on every machine, and you do the work with them yourself: checks, reading files, running commands, looking at a screenshot. Each shell call is a fresh shell in the machine's workspace, so nothing carries over between calls. Background children are killed when the command exits, nohup or not. To leave something running (a server, a watcher), start it in its own process group with its output in a file: `bash -c 'set -m; nohup CMD >CMD.log 2>&1 &'`.
             - A shell call holds the conversation until its command exits: the user's next messages wait for it. For finite work that takes more than a few minutes (a backup, a long build), start it the same way with its exit code in a file too, `bash -c 'set -m; nohup sh -c "CMD; echo \$? >CMD.exit" >CMD.log 2>&1 &'`, then use schedule with in_minutes to check the log and exit code later and report. Promise to report back only when you've scheduled that check.
             - Use list_machines to see which machines there are and which are online. If the user doesn't say which machine, pick a sensible one and say which you picked.
             - Keep durable facts about the user, their machines and their preferences in memory with update_memory. Your memory is below.
             - Use schedule for anything recurring or for later. A scheduled prompt arrives here as a message starting with "[Scheduled]", and you act on it then.
             - Never invent results. If a machine is offline or a command failed, say so plainly.
             - The user talks to you from a panel that floats over the hub's pages. A message may start with a note of the page they have open, beginning "[Looking at"; "this" and "here" mean that page. You can't read or change projects, context files or threads with tools yet, but you can look in a project's folder on any machine with shell.
             """
             |> String.trim_trailing()
  end

  test "says what a page note at the start of a message means" do
    prompt = Prompt.system_prompt(settings(), "", @now)
    assert prompt =~ ~s(beginning "[Looking at"; "this" and "here" mean that page)
    assert prompt =~ "you can look in a project's folder on any machine with shell"
  end

  test "opens with Blip's voice, in the owner's name when it's set" do
    prompt = Prompt.system_prompt(settings(), "", @now)
    assert String.starts_with?(prompt, "You are Blip, the assistant in the user's Photon hub.")
    assert prompt =~ "You run commands on the user's machines yourself"
    refute prompt =~ "You do not run commands yourself"
    assert prompt =~ "## How you work"
    refute prompt =~ "The user's name is"

    named = Prompt.system_prompt(settings(%{"user_name" => " Henry "}), "", @now)
    assert String.starts_with?(named, "You are Blip, the assistant in Henry's Photon hub.")
    assert named =~ "You run commands on Henry's machines yourself"
    assert named =~ "The user's name is Henry."
  end
end
