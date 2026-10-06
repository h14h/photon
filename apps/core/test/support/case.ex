defmodule PhotonCore.Case do
  @moduledoc """
  The case every core test uses: it aliases the modules under test and
  imports the fixture builders, so test files start with what they test.

      use PhotonCore.Case, async: true

  Tests are laid out by layer: `test/core` for the pure modules (no
  processes, no HTTP), `test/boundary` for `PhotonCore.LLM.stream/3` called
  as its users call it, against a stub API, and `test/property` for the
  StreamData properties of both.
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  use ExUnit.CaseTemplate

  using do
    quote do
      alias PhotonCore.{ID, LLM, Message, Operation, Output}
      alias PhotonCore.LLM.{Error, HTTPError, Mock, Responses, Retry, SSE}
      alias PhotonCore.LLM.Responses.{Request, Response}

      import PhotonCore.Fixtures
    end
  end
end
