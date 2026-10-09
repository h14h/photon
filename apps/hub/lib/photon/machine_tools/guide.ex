defmodule Photon.MachineTools.Guide do
  @moduledoc """
  The prompt lines about the machine tools that Blip's prompt
  (`Photon.Assistant.Prompt`) and a thread's share, so the two say the same
  thing about how a `shell` call behaves. Each prompt adds its own lines
  around them: Blip's about `schedule`, a thread's about its project's
  folder.
  """

  # Functional core: no processes, no I/O.
  use Boundary, top_level?: true, type: :strict, deps: []

  @doc """
  What a `shell` call is like, for a prompt's Markdown list: a fresh shell
  per call in `where` ("the machine's workspace", "the project's folder"),
  background children killed with the command's process group, the
  `set -m; nohup` pattern for something that keeps running, and that a
  call holds the conversation until its command exits.

  It is two list items. The caller writes the first item's `- ` and any
  lead-in before it; the second item starts with its own `- ` on a new
  line, and the caller may go on with that item's text after it.
  """
  @spec shell(String.t()) :: String.t()
  def shell(where) do
    "Each shell call is a fresh shell in #{where}, so nothing carries over between calls. " <>
      "Background children are killed when the command exits, nohup or not. " <>
      "To leave something running (a server, a watcher), start it in its own process group " <>
      "with its output in a file: `bash -c 'set -m; nohup CMD >CMD.log 2>&1 &'`.\n" <>
      "- A shell call holds the conversation until its command exits: the user's next messages wait for it."
  end
end
