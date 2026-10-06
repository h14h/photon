defmodule Photon.MachineTools.GuideTest do
  @moduledoc "The shell lines Blip's prompt and a thread's share."

  use Photon.Case, async: true

  alias Photon.MachineTools.Guide

  test "names where each call's fresh shell runs, for Blip" do
    assert Guide.shell("the machine's workspace") ==
             "Each shell call is a fresh shell in the machine's workspace, so nothing carries over between calls. " <>
               "Background children are killed when the command exits, nohup or not. " <>
               "To leave something running (a server, a watcher), start it in its own process group " <>
               "with its output in a file: `bash -c 'set -m; nohup CMD >CMD.log 2>&1 &'`.\n" <>
               "- A shell call holds the conversation until its command exits: the user's next messages wait for it."
  end

  test "and for a thread, in its project's folder" do
    text = Guide.shell("the project's folder")

    assert String.starts_with?(
             text,
             "Each shell call is a fresh shell in the project's folder, so nothing carries over between calls."
           )

    assert text =~ "bash -c 'set -m; nohup CMD >CMD.log 2>&1 &'"
    refute text =~ "workspace"

    assert String.ends_with?(
             text,
             "\n- A shell call holds the conversation until its command exits: the user's next messages wait for it."
           )
  end
end
