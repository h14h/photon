defmodule Photon.Case do
  @moduledoc """
  The case for the hub's core tests: it aliases the pure modules and
  imports the fixture builders, so test files start with what they test.

      use Photon.Case, async: true

  Tests are laid out by layer:

    * `test/core` - the functional core: no database, no processes, no
      files, so every file runs `async: true`
    * `test/boundary` - the contexts (`Photon.Durable`,
      `Photon.NodeSessions`, `Photon.Assistant`, `Photon.Provision`)
      through their public API, the way the web layer and nodes call them,
      against a real database and the harness's processes
      (`Photon.DataCase`)
    * `test/web` - the outer boundary: the node channel, LiveViews,
      controllers and plugs (`PhotonWeb.ConnCase`)
    * `test/property` - StreamData properties of both
    * `test/integration` - the hub with a real node over a websocket
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Photon.Assistant.{Memory, Notice, Prompt, Transcript}

      alias Photon.Durable.{
        Changes,
        Context,
        Inbox,
        Policy,
        Queries,
        Schema,
        ToolCall,
        Turn
      }

      alias Photon.NodeSessions.Mirror
      alias Photon.Provision.{Jobs, Script}
      alias PhotonCore.Message

      import Photon.Fixtures
    end
  end
end
