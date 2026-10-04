defmodule PhotonCore.Property.LLMStreamTest do
  @moduledoc """
  A boundary property: an answer streamed over HTTP, cut into any HTTP
  chunks, gives `PhotonCore.LLM.stream/3` the same result and the same
  events as the pure fold of the whole body. It checks the adapter's
  plumbing (state carried across Req's chunks, events passed on in order);
  what the fold computes is the core's properties' business.
  """

  use PhotonCore.Case, async: true
  use ExUnitProperties

  alias PhotonCore.{Generators, StubProvider}

  property "an answer streamed in any HTTP chunks reads as the pure fold of its body" do
    check all(
            {chunks, _message, _model} <- Generators.streamed_answer(),
            cuts <- Generators.cuts(16),
            max_runs: 100
          ) do
      body = sse_body(chunks ++ [:done])
      StubProvider.streams_in_pieces(__MODULE__, split_at(body, cuts))
      config = stub_config(__MODULE__, max_attempts: 1)

      assert capture_events(&LLM.stream(request(), config, &1)) == read_stream([body])
    end
  end
end
