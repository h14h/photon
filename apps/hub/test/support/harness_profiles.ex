defmodule Photon.HarnessProfiles do
  @moduledoc """
  Extra conversation profiles for harness regression tests, registered for
  one test with `use_profiles/0`:

    * `"block"` - `Photon.TestProfile`, except that a request whose last
      message is `"block"` or `"block wait"` tells the test (the process in
      the `:test_listener` app env) `{:model_request, pid}` and waits for
      `:release`, then answers (`"block wait"` with a call to the wait tool);
      `"block wait block"` does the same, and holds the request after the
      tool's result too
    * `"loop"` - a model that calls the wait tool in every round
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  alias Photon.HarnessProfiles.{Block, Loop}

  @doc "Registers the profiles and makes the calling test the listener."
  def use_profiles do
    config = Application.get_env(:photon, Photon.Durable)
    profiles = Map.merge(config[:profiles], %{"block" => Block, "loop" => Loop})
    Photon.TestConfig.put_env(:photon, Photon.Durable, Keyword.put(config, :profiles, profiles))
    Photon.TestConfig.put_env(:photon, :test_listener, self())
  end
end
