defmodule PhotonNode.Case do
  @moduledoc """
  The case for the node's core tests: it aliases the pure modules and
  imports the fixture builders, so test files start with what they test.

      use PhotonNode.Case, async: true

  Tests are laid out by layer: `test/core` for the functional core (no
  processes, no files; sessions run through `PhotonNode.SessionDriver`),
  `test/boundary` for the harness API, the coordinator, operation
  processes and the hub connection, run as a node in a temporary directory
  (`PhotonNode.HarnessCase`), and `test/property` for the StreamData
  properties of both.
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  use ExUnit.CaseTemplate

  using do
    quote do
      alias PhotonCore.Message
      alias PhotonNode.Harness.{Context, Inbox, ModelRequest, Operation, Output, Session, Tools}
      alias PhotonNode.SessionDriver, as: Driver

      import PhotonNode.Fixtures
    end
  end
end
