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

    test "drops an older hub's provider and key, and efforts it doesn't know" do
      normalized =
        Settings.normalize(
          %{"provider" => "fireworks", "api_key" => "fw", "reasoning" => "ultra"},
          settings()
        )

      refute Map.has_key?(normalized, "provider")
      refute Map.has_key?(normalized, "api_key")
      assert normalized["reasoning"] == ""
    end

    test "consent for scheduled work is on only when the box was ticked" do
      refute Settings.scheduled_work?(settings())
      assert Settings.scheduled_work?(settings(%{"scheduled_work" => "true"}))
      refute Settings.scheduled_work?(settings(%{"scheduled_work" => "yes please"}))
    end
  end

  describe "the model" do
    test "is the setting, else the default" do
      assert Settings.model(settings()) == Settings.default_model()
      assert Settings.model(settings(%{"model" => "gpt-6-luna"})) == "gpt-6-luna"
    end

    test "is labelled for the app shell the way ChatGPT names it" do
      assert Settings.model_label(settings(%{"model" => "gpt-6.1-sol"})) == "GPT-6.1 Sol"
      assert Settings.model_label("gpt-5.6-terra") == "GPT-5.6 Terra"
      assert Settings.model_label("gpt-5.5") == "GPT-5.5"
      assert Settings.model_label("o9") == "o9"
    end

    test "goes to nodes with the effort, blank as nil" do
      assert Settings.node_config(settings()) ==
               %{"model" => Settings.default_model(), "reasoning" => nil}

      assert Settings.node_config(settings(%{"reasoning" => "low"}))["reasoning"] == "low"
    end
  end
end
