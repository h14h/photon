defmodule PhotonCore do
  @moduledoc """
  Code the Photon hub and nodes share:

    * `PhotonCore.Message`: the provider-neutral conversation format both
      harnesses persist.
    * `PhotonCore.LLM`: one streamed model request, with retries: to the
      OpenAI Responses API with a Sign in with ChatGPT token (the hub), to
      the hub's model relay (nodes), or to the scripted mock (tests).
    * `PhotonCore.ID`: time-sortable identifiers.

  It's a library: no application, no processes. Requests run in the caller's
  process. The layers, after *Designing Elixir Systems with OTP*:

    * data: `Message` (string-keyed maps that round-trip through JSON),
      `LLM.Error`, and the request, config and response maps typed in
      `PhotonCore.LLM`
    * functional core, pure: `LLM.SSE`, `LLM.Retry`, `LLM.HTTPError`,
      `LLM.Responses.Request`, `LLM.Responses.Response`, `LLM.Relay.Wire`,
      `Message`, `ID.encode/3`, and the mock script `LLM.MockAgent`
    * boundary: `PhotonCore.LLM` is the API. Behind it, `LLM.Responses`
      and `LLM.Relay` do the HTTP and `LLM.Mock` answers with a script; all
      report events through the caller's `on_event`. `ID.new/1` reads the
      clock and RNG.
  """

  # The shared data and utilities: the message format and IDs. Pure, so its
  # only outside dependency is JSON. `PhotonCore.LLM` (the model client) and
  # `PhotonCore.LLM.Error` are boundaries of their own, so a functional core
  # elsewhere can depend on this one without reaching the HTTP client.
  use Boundary, type: :strict, deps: [Jason], exports: [ID, Message]
end
