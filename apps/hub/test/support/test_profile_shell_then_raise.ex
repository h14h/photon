defmodule Photon.TestProfile.ShellThenRaise do
  @moduledoc false
  # Starts a shell op as `shell` does, then raises when the call resumes,
  # so a test can see that a raise after the op exists still cancels it.
  @behaviour Photon.Durable.Tool

  alias Photon.MachineTools.{Call, Shell}

  @impl true
  def name, do: "shell_then_raise"
  @impl true
  def description, do: "Starts a shell op, then raises."
  @impl true
  def parameters, do: Shell.parameters()
  @impl true
  def replay, do: :safe
  @impl true
  def execute(args, api), do: Call.execute("shell", args, api)
  @impl true
  def resume(_state, _api), do: raise("boom after the op started")
  @impl true
  def on_interrupt(api, tx), do: Call.on_interrupt(api, tx)
end
