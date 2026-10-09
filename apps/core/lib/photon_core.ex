defmodule PhotonCore do
  @moduledoc """
  Code the Photon hub and nodes share: the conversation format
  (`PhotonCore.Message`), the model client (`PhotonCore.LLM`), operation
  snapshots and the messages about them (`PhotonCore.Operation`,
  `PhotonCore.Operation.Wire`), output bounds (`PhotonCore.Output`) and
  IDs (`PhotonCore.ID`).

  A library: no application and no processes. Model requests run in the
  caller's process.
  """

  # Pure, so its only outside dependency is JSON. `PhotonCore.LLM` and
  # `PhotonCore.LLM.Error` are boundaries of their own, so a functional core
  # elsewhere can depend on this one without reaching the HTTP client.
  use Boundary,
    type: :strict,
    deps: [Jason],
    exports: [ID, Message, Operation, Operation.Result, Operation.Wire, Output]
end
