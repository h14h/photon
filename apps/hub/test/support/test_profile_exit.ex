defmodule Photon.TestProfile.Exit do
  @moduledoc false
  # Exits its step process, which the tool task doesn't rescue, so the
  # Scheduler fails the call's task (ToolTask.on_fail/3).
  @behaviour Photon.Durable.Tool

  @impl true
  def name, do: "exit"
  @impl true
  def description, do: "Exits its step."
  @impl true
  def parameters, do: %{"type" => "object", "properties" => %{}}
  @impl true
  def execute(_args, _api), do: exit(:boom)
end
