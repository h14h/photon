defmodule Photon.MachineTools do
  @moduledoc """
  The tools that run work on the user's machines (`shell`, `view_image`,
  `list_machines`). They live outside `Photon.Assistant` because more than
  one profile uses them (Blip's and a thread's). Each call runs in the
  conversation's working directory on the machine it names (`api.workdir`,
  from the profile): the machine's workspace for Blip, the project's
  folder for a thread.

  Each `shell` or `view_image` call is one operation on one machine
  (`Photon.Machines`), parked on the op's signal until the machine reports
  the result. The parked task holds the call's state, so there is no
  process per call here: the durable harness waits, and the machine's
  channel carries the messages. `Photon.MachineTools.Call` has the steps.

  `Photon.MachineTools.Guide` and `Photon.MachineTools.MockPhrases` are
  top-level boundaries so other contexts' pure modules can use them.
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
