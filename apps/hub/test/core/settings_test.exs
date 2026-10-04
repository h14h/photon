defmodule Photon.SettingsTest do
  @moduledoc "Hub settings as pure functions of a settings map."

  use Photon.Case, async: true

  alias Photon.Settings

  describe "normalize" do
    test "fills every key from the defaults and trims what the form sent" do
      assert Settings.normalize(%{"model" => "  m  ", "extra" => "x"}, settings()) ==
               Map.put(settings(), "model", "m")
    end

    test "keeps instructions as written" do
      assert Settings.normalize(%{"instructions" => " two\nlines "}, settings())["instructions"] ==
               " two\nlines "
    end

    test "falls back to the mock model and the default effort for values it doesn't know" do
      normalized = Settings.normalize(%{"provider" => "acme", "reasoning" => "max"}, settings())
      assert normalized["provider"] == "mock"
      assert normalized["reasoning"] == ""
    end

    test "defaults to Fireworks when its key is in the environment" do
      assert Settings.defaults(env())["provider"] == "mock"
      assert Settings.defaults(env(%{"FIREWORKS_API_KEY" => "fw"}))["provider"] == "fireworks"
    end
  end

  describe "the model" do
    test "is the setting, else the provider's default; the mock has its own" do
      assert Settings.model(settings(%{"provider" => "mock", "model" => "x"})) == "mock-model"
      assert Settings.model(settings(%{"provider" => "openai", "model" => "gpt-x"})) == "gpt-x"

      assert Settings.model(settings(%{"provider" => "fireworks"})) ==
               "accounts/fireworks/models/deepseek-v4p1-flash"
    end

    test "is labelled for the app shell by its last path part and its provider" do
      assert Settings.model_label(settings()) == "Mock model"

      assert Settings.model_label(settings(%{"provider" => "fireworks"})) ==
               "deepseek-v4p1-flash · Fireworks"
    end

    test "goes to nodes with the effort, blank as nil" do
      assert Settings.node_config(settings()) == %{"model" => "mock-model", "reasoning" => nil}

      assert Settings.node_config(settings(%{"reasoning" => "low"})) ==
               %{"model" => "mock-model", "reasoning" => "low"}
    end
  end

  describe "keys" do
    test "providers that need none always have one" do
      for provider <- ~w(mock ollama custom),
          do: assert(Settings.key?(settings(%{"provider" => provider}), env()))
    end

    test "come from the settings or the hub's environment" do
      fireworks = settings(%{"provider" => "fireworks"})

      refute Settings.key?(fireworks, env())
      assert Settings.key?(%{fireworks | "api_key" => "fw"}, env())
      assert Settings.key?(fireworks, env(%{"FIREWORKS_API_KEY" => "fw"}))

      assert Settings.env_key?("fireworks", env(%{"FIREWORKS_API_KEY" => "fw"}))
      refute Settings.env_key?("fireworks", env())
      refute Settings.env_key?("mock", env())
    end

    test "a blank key in the form keeps the saved one, unless asked to clear it" do
      saved = settings(%{"api_key" => "old"})

      assert Settings.keep_key(%{"api_key" => ""}, saved)["api_key"] == "old"
      assert Settings.keep_key(%{"api_key" => "new"}, saved)["api_key"] == "new"
      assert Settings.keep_key(%{"api_key" => "", "clear_key" => true}, saved)["api_key"] == ""
    end
  end
end
