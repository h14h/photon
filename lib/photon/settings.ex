defmodule Photon.Settings do
  @moduledoc """
  Playground settings, persisted as JSON in the data directory.

  API keys are stored in plain text (mode 0600) because this is a local tool,
  and are sent to the node with each run. Leaving a key blank lets the runner
  fall back to the provider's usual environment variable, such as
  `OPENAI_API_KEY`, on the node that runs it.
  """

  alias Photon.Paths

  @providers [
    {"mock", "Mock model (built in, no API key)"},
    {"openai", "OpenAI"},
    {"openai-codex", "OpenAI Codex (ChatGPT login)"},
    {"openrouter", "OpenRouter"},
    {"fireworks", "Fireworks"},
    {"ollama", "Ollama"}
  ]

  @provider_env %{
    "openai" => "OPENAI_API_KEY",
    "openrouter" => "OPENROUTER_API_KEY",
    "fireworks" => "FIREWORKS_API_KEY"
  }

  @thinking_levels ~w(low medium high xhigh max)
  @tools ~w(Bash ViewImage)

  @defaults %{
    "provider" => "mock",
    "model" => "",
    "api_key" => "",
    "base_url" => "",
    "thinking_level" => "high",
    "max_attempts" => "",
    "system_prompt" => "",
    "workspace" => "",
    "disallowed_tools" => [],
    "node" => "local"
  }

  @run_keys ~w(provider model api_key base_url thinking_level system_prompt disallowed_tools max_attempts workspace)

  def providers, do: @providers
  def thinking_levels, do: @thinking_levels
  def tools, do: @tools
  def defaults, do: @defaults

  @doc "Name of the environment variable a provider reads its key from, if any."
  def provider_key_env(provider), do: Map.get(@provider_env, provider)

  def load do
    with {:ok, body} <- File.read(Paths.settings_file()),
         {:ok, map} when is_map(map) <- Jason.decode(body) do
      normalize(map)
    else
      _ -> @defaults
    end
  end

  @topic "settings"

  @doc "PubSub topic carrying `{:settings_changed, settings}`, so every open tab stays current."
  def topic, do: @topic

  def save(params) do
    settings = normalize(params)
    path = Paths.settings_file()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode_to_iodata!(settings, pretty: true))
    File.chmod!(path, 0o600)
    Phoenix.PubSub.broadcast(Photon.PubSub, @topic, {:settings_changed, settings})
    settings
  end

  @doc "Coerces form params into a complete settings map."
  def normalize(params) do
    base = Map.merge(@defaults, Map.take(params, Map.keys(@defaults)))

    base
    |> Map.update!("disallowed_tools", fn
      list when is_list(list) -> Enum.filter(list, &(&1 in @tools))
      _ -> []
    end)
    |> Map.update!("thinking_level", &if(&1 in @thinking_levels, do: &1, else: "high"))
    |> Map.update!("provider", fn p ->
      if p in Enum.map(@providers, &elem(&1, 0)), do: p, else: "mock"
    end)
    |> Map.new(fn
      {k, v} when is_binary(v) and k != "system_prompt" -> {k, String.trim(v)}
      pair -> pair
    end)
  end

  @doc "The part of the settings sent to a node with each run."
  def run_config(settings), do: Map.take(settings, @run_keys)
end
