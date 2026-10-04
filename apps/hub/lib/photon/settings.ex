defmodule Photon.Settings do
  @moduledoc """
  Hub settings, persisted as JSON (mode 0600) in the data directory.

  One model serves both the assistant and the agents on nodes. Nodes never
  see the API key: their requests go through the hub's model proxy
  (`PhotonWeb.ModelProxyController`), which adds it. A blank key falls back to
  the provider's environment variable on the hub, such as `FIREWORKS_API_KEY`.

  `load/0`, `save/1` and `defaults/0` read or write the file and the
  environment. Everything else is a pure function of a settings map, so
  callers load once and pass the map along.
  """

  use Boundary, deps: [Photon.Events, Photon.Paths, PhotonCore.LLM]

  alias Photon.{Events, Paths}
  alias PhotonCore.LLM

  @providers [
    {"fireworks", "Fireworks"},
    {"openai", "OpenAI"},
    {"openrouter", "OpenRouter"},
    {"ollama", "Ollama"},
    {"custom", "Other (OpenAI-compatible)"},
    {"mock", "Mock model (no API key)"}
  ]

  @reasoning ["", "low", "medium", "high"]

  @keys ~w(provider model api_key base_url reasoning instructions timezone user_name)

  @typedoc "A complete settings map: every key in `@keys`, as text."
  @type t :: %{String.t() => String.t()}

  @spec providers() :: [{String.t(), String.t()}]
  def providers, do: @providers

  @spec reasoning_levels() :: [String.t()]
  def reasoning_levels, do: @reasoning

  @doc "The settings a fresh hub starts with: the mock model unless `FIREWORKS_API_KEY` is set."
  @spec defaults((String.t() -> String.t() | nil)) :: t()
  def defaults(env \\ &System.get_env/1) do
    %{
      "provider" => if(env.("FIREWORKS_API_KEY") in [nil, ""], do: "mock", else: "fireworks"),
      "model" => "",
      "api_key" => "",
      "base_url" => "",
      "reasoning" => "",
      "instructions" => "",
      "timezone" => "",
      "user_name" => ""
    }
  end

  @spec load() :: t()
  def load do
    with {:ok, body} <- File.read(Paths.settings_file()),
         {:ok, map} when is_map(map) <- Jason.decode(body) do
      normalize(map)
    else
      _ -> defaults()
    end
  end

  @topic "settings"

  @doc "PubSub topic carrying `{:settings_changed, settings}`."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribes to `{:settings_changed, settings}`."
  @spec subscribe() :: :ok
  def subscribe, do: Events.subscribe(@topic)

  @doc """
  Saves settings from form params and announces them. A blank key keeps the
  saved one unless the params say `"clear_key"`.
  """
  @spec save(map()) :: t()
  def save(params) do
    settings = normalize(keep_key(params, load()))
    path = Paths.settings_file()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode_to_iodata!(settings, pretty: true))
    File.chmod!(path, 0o600)
    :ok = Events.broadcast(@topic, {:settings_changed, settings})
    settings
  end

  @doc false
  # A blank key field in the form keeps the saved key.
  @spec keep_key(map(), t()) :: map()
  def keep_key(params, current) do
    if Map.get(params, "api_key") in [nil, ""] and not Map.get(params, "clear_key", false),
      do: Map.put(params, "api_key", current["api_key"]),
      else: params
  end

  @doc "Coerces form params into a complete settings map, over `defaults`."
  @spec normalize(map(), t()) :: t()
  def normalize(params, defaults \\ defaults()) do
    defaults
    |> Map.merge(Map.take(params, @keys))
    |> Map.new(fn
      {"instructions", v} -> {"instructions", to_string(v)}
      {k, v} -> {k, v |> to_string() |> String.trim()}
    end)
    |> Map.update!(
      "provider",
      &if(&1 in Enum.map(@providers, fn {id, _} -> id end), do: &1, else: "mock")
    )
    |> Map.update!("reasoning", &if(&1 in @reasoning, do: &1, else: ""))
  end

  @doc "The model ID in use: the setting, else the provider's default."
  @spec model(t()) :: String.t() | nil
  def model(settings) do
    case {settings["provider"], settings["model"]} do
      {"mock", _} -> "mock-model"
      {_, model} when model != "" -> model
      {provider, _} -> (LLM.provider(provider) || %{})[:default_model]
    end
  end

  @doc "How the app shell names the model in use: the model's last path part and the provider."
  @spec model_label(t()) :: String.t()
  def model_label(%{"provider" => "mock"}), do: "Mock model"

  def model_label(settings) do
    model = model(settings) || "no model"

    provider =
      Enum.find_value(@providers, settings["provider"], fn {id, name} ->
        id == settings["provider"] && name
      end)

    "#{model |> String.split("/") |> List.last()} · #{provider}"
  end

  @doc """
  Whether the provider has a key, from settings or the hub's environment
  (`env` reads it; `System.get_env/1` by default).
  """
  @spec key?(t(), (String.t() -> String.t() | nil)) :: boolean()
  def key?(settings, env \\ &System.get_env/1) do
    case settings["provider"] do
      provider when provider in ["mock", "ollama", "custom"] ->
        true

      provider ->
        LLM.resolve(%{provider: provider, api_key: settings["api_key"]}, env)[:api_key] not in [
          nil,
          ""
        ]
    end
  end

  @doc "Whether the hub's environment has a key for `provider`, as the settings page tells."
  @spec env_key?(String.t() | nil, (String.t() -> String.t() | nil)) :: boolean()
  def env_key?(provider, env \\ &System.get_env/1) do
    case LLM.provider(provider) do
      %{key_env: key_env} when is_binary(key_env) -> env.(key_env) not in [nil, ""]
      _ -> false
    end
  end

  @doc "A `PhotonCore.LLM` config for the provider; `script` answers for the mock."
  @spec llm_config(t(), module() | nil) :: LLM.config()
  def llm_config(settings, script) do
    %{
      provider: settings["provider"],
      api_key: settings["api_key"],
      base_url: settings["base_url"],
      script: script,
      send_reasoning_effort: settings["reasoning"] != ""
    }
    |> LLM.resolve()
  end

  @doc "The model settings sent to a node with each input."
  @spec node_config(t()) :: map()
  def node_config(settings) do
    %{"model" => model(settings), "reasoning" => blank_nil(settings["reasoning"])}
  end

  defp blank_nil(""), do: nil
  defp blank_nil(value), do: value
end
