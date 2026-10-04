defmodule PhotonCore.LLM.ResolveTest do
  @moduledoc """
  Config resolution is pure once the environment is passed in, so these run
  without touching the OS environment.
  """

  use PhotonCore.Case, async: true

  defp no_env(_name), do: nil
  defp env("FIREWORKS_API_KEY"), do: "from-env"
  defp env(_name), do: nil

  describe "resolve/2" do
    test "resolve fills in the provider's URL and key variable" do
      config = LLM.resolve(%{provider: "fireworks", api_key: "x"}, &no_env/1)
      assert config.base_url == "https://api.fireworks.ai/inference/v1"
      assert config.api_key == "x"

      assert LLM.resolve(%{provider: "fireworks", api_key: ""}, &env/1).api_key == "from-env"
      assert LLM.resolve(%{provider: "fireworks"}, &no_env/1).api_key == nil
    end

    test "an explicit base URL wins, and keeps the caller's other keys" do
      config =
        LLM.resolve(%{provider: "openai", base_url: "http://proxy/v1", script: nil}, &no_env/1)

      assert config.base_url == "http://proxy/v1"
      assert Map.has_key?(config, :script)
    end

    test "a provider with no key variable, or none at all, gets no key from the environment" do
      assert %{api_key: nil, base_url: "http://127.0.0.1:11434/v1"} =
               LLM.resolve(%{provider: "ollama"}, &env/1)

      assert %{api_key: nil, base_url: nil} = LLM.resolve(%{provider: "custom"}, &env/1)
    end

    test "a mock config passes through unchanged" do
      config = %{provider: "mock", script: PhotonCore.EchoScript}
      assert LLM.resolve(config, &env/1) == config
    end
  end

  describe "providers" do
    test "every provider has a name and a base URL, and its ID looks it up" do
      for {id, provider} <- LLM.providers() do
        assert is_binary(provider.name) and is_binary(provider.base_url)
        assert LLM.provider(id) == provider
      end

      assert LLM.provider("nope") == nil
    end
  end
end
