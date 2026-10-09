defmodule Photon.MachineTools do
  @moduledoc """
  The tools that run work on the user's machines: `shell` runs a command,
  `view_image` shows the model an image file, and `list_machines` says which
  machines there are and which skills are turned on for each, read from
  `Photon.Skills`. They live outside `Photon.Assistant` because more than
  one profile uses them (Blip's and a thread's); a profile lists `tools/0`
  among its own. Each call runs in the conversation's working directory on
  the machine it names (`api.workdir`, from the profile): the machine's
  workspace for Blip, the project's folder for a thread.

  Each `shell` or `view_image` call is one operation on one machine
  (`Photon.Machines`). The call derives the op ID from its durable task,
  commits the op, and parks on the op's signal (`signal_key/1`) until the
  machine reports the result, checking once a minute in between. The
  parked task holds the call's state, so there is no process per call
  here: the durable harness waits, and the machine's channel carries the
  messages. `Photon.MachineTools.Call` has the steps.

  By layer:

    * functional core (pure): `Photon.MachineTools.Translate` (arguments
      to an operation, a snapshot to a tool result) and
      `Photon.MachineTools.Wait` (the op ID, when to check, when to give
      up, and the offline message); and, exported for other contexts'
      pure modules, `Photon.MachineTools.Guide` (the prompt lines about
      `shell` that Blip's prompt and a thread's share) and
      `Photon.MachineTools.MockPhrases` (the machine phrasings and result
      relay that Blip's scripted model and a thread's share). A pure
      module elsewhere lists `Photon.MachineTools` in its Boundary deps
      to reach them.
    * boundary: the `Photon.Durable.Tool` modules
      `Photon.MachineTools.Shell`, `Photon.MachineTools.ViewImage` and
      `Photon.MachineTools.ListMachines`, and `Photon.MachineTools.Call`,
      which the first two share
  """

  use Boundary,
    deps: [Photon.Durable, Photon.Machines, Photon.Skills, PhotonCore, PhotonCore.LLM],
    exports: []

  alias Photon.Machines
  alias Photon.MachineTools.{ListMachines, Shell, ViewImage}

  @doc "The tool modules, for a profile's `tools/1`."
  @spec tools() :: [module()]
  def tools, do: [Shell, ViewImage, ListMachines]

  @doc "The signal a call on op `op_id` waits for; it fires when the op has its result."
  @spec signal_key(String.t()) :: String.t()
  defdelegate signal_key(op_id), to: Machines
end
