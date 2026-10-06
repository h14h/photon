defmodule Photon.MachineTools.Shell do
  @moduledoc """
  The `shell` tool: runs one command on a machine and returns its output
  (section 3.1 of `docs/plans/step-1-machine-tools.md`).
  `Photon.MachineTools.Call` does the work.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.MachineTools.{Call, Translate}

  @impl true
  def name, do: "shell"

  @impl true
  def description do
    "Run one command on a machine with its default shell, in the machine's workspace, and return its output. " <>
      "Each call is a fresh shell in its own process group, with stdin from /dev/null; background children are killed " <>
      "when the command exits (nohup doesn't save them: they are in the same group), and the call returns when the " <>
      "command finishes. To leave something running after the call (a server, a watcher), start it as a job in its own " <>
      "process group, with its output in a file: bash -c 'set -m; nohup CMD >CMD.log 2>&1 &'. " <>
      "If the machine is offline, the call waits for it to come back, for up to 10 minutes."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "machine" => %{
          "type" => "string",
          "description" => "The machine's ID, from list_machines."
        },
        "command" => %{
          "type" => "string",
          "description" =>
            "The command to run, at most #{Translate.max_command_bytes()} bytes. Write a longer script to a file in pieces and run the file."
        },
        "max_output_length" => %{
          "type" => "integer",
          "description" =>
            "Keep at most this many characters of stdout and of stderr each (1 to 1000000, default 40000). " <>
              "Longer output keeps its start and end, and says where the full output is on the machine."
        }
      },
      "required" => ["machine", "command"]
    }
  end

  # The op ID comes from the call's task, so a rerun finds the same op.
  @impl true
  def replay, do: :safe

  @impl true
  def execute(args, api), do: Call.execute("shell", args, api)

  @impl true
  def resume(state, api), do: Call.resume(state, api)

  @impl true
  def on_interrupt(api, tx), do: Call.on_interrupt(api, tx)
end
