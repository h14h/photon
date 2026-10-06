defmodule PhotonNode.Harness do
  @moduledoc """
  The node's operation layer: the processes that run the hub's operations
  on this machine, and what they read from it.

    * boundary: `PhotonNode.Harness.Ops`, the API over operation processes,
      and `PhotonNode.Harness.Ops.Owner`, the contract for whatever owns
      them (the executor, `PhotonNode.Executor`); `PhotonNode.Harness.Env`,
      the shell and environment commands run with
    * workers: one process per operation, `PhotonNode.Harness.Ops.Shell`
      for a command and `PhotonNode.Harness.Ops.Job` for a one-shot read
      (`PhotonNode.Harness.Ops.ViewImage`)
    * functional core: `PhotonNode.Harness.Image` (image formats and
      sizes), and the snapshots and output bounds the hub shares
      (`PhotonCore.Operation`, `PhotonCore.Output`)
    * lifecycle: the `PhotonNode` supervisor

  This module holds no code; it names the boundary.
  """

  # The operation layer. `Ops`, `Ops.Owner` and `Env` are for the executor,
  # which runs the hub's operations: it starts, finds and cancels them, owns
  # them, and reads the shell to run commands with.
  use Boundary,
    deps: [PhotonCore],
    exports: [Ops, Ops.Owner, Env]
end
