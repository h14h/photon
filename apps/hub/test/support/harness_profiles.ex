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

  @doc "Registers the profiles and makes the calling test the listener."
  def use_profiles do
    config = Application.get_env(:photon, Photon.Durable)
    profiles = config[:profiles]

    Application.put_env(
      :photon,
      Photon.Durable,
      Keyword.put(
        config,
        :profiles,
        Map.merge(profiles, %{
          "block" => Photon.HarnessProfiles.Block,
          "loop" => Photon.HarnessProfiles.Loop
        })
      )
    )

    Application.put_env(:photon, :test_listener, self())

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:photon, Photon.Durable, config)
      Application.delete_env(:photon, :test_listener)
    end)
  end
end
