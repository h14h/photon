defmodule Photon.MachineTools.ViewImage do
  @moduledoc """
  The `view_image` tool: shows the model an image file on a machine
  (section 3.1 of `docs/plans/step-1-machine-tools.md`).
  `Photon.MachineTools.Call` does the work.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.MachineTools.Call

  @impl true
  def name, do: "view_image"

  @impl true
  def description do
    "Look at an image file on a machine: PNG, JPEG, GIF or WebP, up to about 3.7 MB of image data. " <>
      "For anything larger, make a smaller copy with shell first. " <>
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
        "path" => %{
          "type" => "string",
          "description" => "The image's path: absolute, or relative to the machine's workspace."
        }
      },
      "required" => ["machine", "path"]
    }
  end

  # The op ID comes from the call's task, so a rerun finds the same op.
  @impl true
  def replay, do: :safe

  @impl true
  def execute(args, api), do: Call.execute("view_image", args, api)

  @impl true
  def resume(state, api), do: Call.resume(state, api)

  @impl true
  def on_interrupt(api, tx), do: Call.on_interrupt(api, tx)
end
