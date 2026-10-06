defmodule Photon.Settings do
  @moduledoc """
  Hub settings, persisted as JSON (mode 0600) in the data directory.

  The model comes from the signed-in ChatGPT plan (`Photon.ChatGPT`); these
  are the choices about it: which model Blip uses and how hard it reasons. The rest is what Blip should know about the user
  (their name, time zone and standing instructions), and whether the user
  lets Photon use their plan for scheduled work that runs while they're
  away, which Sign in with ChatGPT asks an app to get express consent for.

  `load/0` and `save/1` read or write the file. Everything else is a pure
  function of a settings map, so callers load once and pass the map along.
  """

  use Boundary, deps: [Photon.Events, Photon.Paths, Photon.PrivateFile]

  alias Photon.{Events, Paths, PrivateFile}

  # The model Codex itself starts with, used until the user picks one.
  @default_model "gpt-6.1-sol"

  @reasoning ["", "low", "medium", "high", "xhigh"]

  @keys ~w(model reasoning instructions timezone user_name scheduled_work)

  @typedoc "A complete settings map: every key in `@keys`, as text."
  @type t :: %{String.t() => String.t()}

  @spec reasoning_levels() :: [String.t()]
  def reasoning_levels, do: @reasoning

  @spec default_model() :: String.t()
  def default_model, do: @default_model

  @doc "The settings a fresh hub starts with."
  @spec defaults() :: t()
  def defaults do
    %{
      "model" => "",
      "reasoning" => "",
      "instructions" => "",
      "timezone" => "",
      "user_name" => "",
      "scheduled_work" => "false"
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

  @doc "Saves settings from form params (over the saved ones) and announces them."
  @spec save(map()) :: t()
  def save(params) do
    settings = normalize(params, load())

    :ok =
      PrivateFile.write!(Paths.settings_file(), Jason.encode_to_iodata!(settings, pretty: true))

    :ok = Events.broadcast(@topic, {:settings_changed, settings})
    settings
  end

  @doc """
  Coerces form params into a complete settings map, over `defaults`. Keys
  it doesn't know (such as an older hub's provider and key) are dropped.
  """
  @spec normalize(map(), t()) :: t()
  def normalize(params, defaults \\ defaults()) do
    defaults
    |> Map.merge(Map.take(params, @keys))
    |> Map.new(fn
      {"instructions", v} -> {"instructions", to_string(v)}
      {k, v} -> {k, v |> to_string() |> String.trim()}
    end)
    |> Map.update!("reasoning", &if(&1 in @reasoning, do: &1, else: ""))
    |> Map.update!("scheduled_work", &if(&1 == "true", do: "true", else: "false"))
  end

  @doc """
  The reasoning effort to ask for: the setting, or nil for the model's
  default. Every conversation (Blip's and each thread's) uses it.
  """
  @spec reasoning(t()) :: String.t() | nil
  def reasoning(%{"reasoning" => ""}), do: nil
  def reasoning(settings), do: settings["reasoning"]

  @doc "The model in use: the setting, else the default."
  @spec model(t()) :: String.t()
  def model(%{"model" => ""}), do: @default_model
  def model(settings), do: settings["model"]

  @doc ~s(How the app shell names a model: "gpt-6.1-sol" is "GPT-6.1 Sol".)
  @spec model_label(t() | String.t()) :: String.t()
  def model_label(%{} = settings), do: settings |> model() |> model_label()

  def model_label("gpt-" <> rest) do
    case String.split(rest, "-") do
      [version | words] ->
        Enum.join(["GPT-" <> version | Enum.map(words, &String.capitalize/1)], " ")

      [] ->
        "GPT"
    end
  end

  def model_label(model), do: model

  @doc "Whether the user lets Photon use their plan for scheduled work."
  @spec scheduled_work?(t()) :: boolean()
  def scheduled_work?(settings), do: settings["scheduled_work"] == "true"
end
