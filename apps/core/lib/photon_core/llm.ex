defmodule PhotonCore.LLM do
  @moduledoc """
  One model request, streamed, with retries. This is the core app's API;
  the modules behind it are free to change.

  A request is a map:

    * `:model` - the provider's model ID
    * `:system` - system prompt text
    * `:messages` - a `PhotonCore.Message` conversation
    * `:tools` - `[%{"name", "description", "parameters" (JSON Schema)}]`
    * `:reasoning` - thinking level, sent only when the config allows it
    * `:max_tokens` - optional output cap

  A config says where to send it:

    * `:provider` - a key of `providers/0`, `"custom"`, or `"mock"`
    * `:base_url`, `:api_key` - default to the provider's
    * `:script` - for `"mock"`, the module that answers (see `PhotonCore.LLM.Mock`)
    * `:max_attempts` - attempts for retryable failures (default 6)
    * `:retry_base_ms` - the first retry's backoff (default 1000)
    * `:receive_timeout` - milliseconds to wait for data (default 180000)
    * `:send_reasoning_effort` - send `:reasoning` as `reasoning_effort`
    * `:extra_body` - fields merged into the request body
    * `:req_options` - extra `Req` options, e.g. a test plug

  Keys it doesn't know are ignored.

  `on_event` receives `{:text, delta}`, `{:reasoning, delta}`,
  `{:tool_call, index, name, args_delta}` while the answer streams, and
  `{:retry, attempt, delay_ms, error}` before a retry, after which deltas
  start over.

  Returns `{:ok, response}` with `"message"` (an assistant message), `"stop"`
  (`"end_turn"`, `"tool_use"`, `"max_tokens"`, ...), `"usage"` (`"input"`,
  `"cached"`, `"output"`, `"reasoning"` tokens) and `"model"`; or
  `{:error, %PhotonCore.LLM.Error{}}`. Provider, network and config
  failures come back as errors, not exceptions.

  `stream/3` runs in the calling process and blocks it for the whole
  request, sleeping between retries (see `PhotonCore.LLM.Retry`). Call it
  from a task, not from a GenServer callback. The library starts no
  processes of its own.
  """

  # The model client: this API in front of the HTTP adapter and the mock.
  use Boundary,
    top_level?: true,
    type: :strict,
    deps: [PhotonCore, PhotonCore.LLM.Error, Jason, Req],
    exports: [ChatCompletions, Mock, MockAgent]

  alias PhotonCore.LLM.{ChatCompletions, Error, Mock, Retry}
  alias PhotonCore.Message

  @typedoc "A model request; see the moduledoc."
  @type request :: %{
          optional(:model) => String.t() | nil,
          optional(:system) => String.t() | nil,
          optional(:messages) => [Message.t()],
          optional(:tools) => [map()],
          optional(:reasoning) => String.t() | nil,
          optional(:max_tokens) => pos_integer() | nil
        }

  @typedoc "Where and how to send a request; see the moduledoc."
  @type config :: %{
          optional(:provider) => String.t() | nil,
          optional(:base_url) => String.t() | nil,
          optional(:api_key) => String.t() | nil,
          optional(:script) => module() | nil,
          optional(:max_attempts) => pos_integer(),
          optional(:retry_base_ms) => non_neg_integer(),
          optional(:receive_timeout) => timeout(),
          optional(:send_reasoning_effort) => boolean(),
          optional(:extra_body) => map(),
          optional(:req_options) => keyword(),
          optional(atom()) => term()
        }

  @typedoc "What `on_event` receives while a request runs."
  @type event ::
          {:text, String.t()}
          | {:reasoning, String.t()}
          | {:tool_call, non_neg_integer(), String.t() | nil, String.t()}
          | {:retry, pos_integer(), non_neg_integer(), Error.t()}

  @type on_event :: (event() -> term())

  @typedoc ~s(`"message"`, `"stop"`, `"usage"` and `"model"`; see the moduledoc.)
  @type response :: %{optional(String.t()) => term()}

  @type provider :: %{
          name: String.t(),
          base_url: String.t(),
          key_env: String.t() | nil,
          default_model: String.t() | nil
        }

  @providers %{
    "fireworks" => %{
      name: "Fireworks",
      base_url: "https://api.fireworks.ai/inference/v1",
      key_env: "FIREWORKS_API_KEY",
      default_model: "accounts/fireworks/models/deepseek-v4p1-flash"
    },
    "openai" => %{
      name: "OpenAI",
      base_url: "https://api.openai.com/v1",
      key_env: "OPENAI_API_KEY",
      default_model: nil
    },
    "openrouter" => %{
      name: "OpenRouter",
      base_url: "https://openrouter.ai/api/v1",
      key_env: "OPENROUTER_API_KEY",
      default_model: "deepseek/deepseek-v4.1-flash"
    },
    "ollama" => %{
      name: "Ollama",
      base_url: "http://127.0.0.1:11434/v1",
      key_env: nil,
      default_model: nil
    }
  }

  @doc "Known providers: id to `%{name, base_url, key_env, default_model}`."
  @spec providers() :: %{String.t() => provider()}
  def providers, do: @providers

  @spec provider(String.t() | nil) :: provider() | nil
  def provider(id), do: Map.get(@providers, id)

  @doc """
  Fills in a config's base URL and key from its provider, falling back to the
  provider's environment variable for the key.
  """
  @spec resolve(config()) :: config()
  def resolve(config), do: resolve(config, &System.get_env/1)

  @doc """
  `resolve/1` with the environment passed in: `get_env` takes a variable's
  name and returns its value or `nil`. Pure when `get_env` is.
  """
  @spec resolve(config(), (String.t() -> String.t() | nil)) :: config()
  def resolve(%{provider: "mock"} = config, _get_env), do: config

  def resolve(config, get_env) do
    defaults = provider(config[:provider]) || %{}

    Map.merge(config, %{
      api_key: api_key(config[:api_key], defaults[:key_env], get_env),
      base_url: base_url(config[:base_url], defaults[:base_url])
    })
  end

  defp api_key(key, key_env, get_env) when key in [nil, ""], do: key_env && get_env.(key_env)
  defp api_key(key, _key_env, _get_env), do: key

  defp base_url(url, default) when url in [nil, ""], do: default
  defp base_url(url, _default), do: url

  @doc "Runs `request` against `config`'s provider. See the moduledoc."
  @spec stream(request(), config(), on_event()) :: {:ok, response()} | {:error, Error.t()}
  def stream(request, config, on_event \\ fn _event -> :ok end) do
    run(request, resolve(config), on_event)
  end

  defp run(request, %{provider: "mock"} = config, on_event),
    do: Mock.stream(request, config, on_event)

  defp run(request, config, on_event) do
    with :ok <-
           require_present(config[:base_url], "no base URL for provider #{config[:provider]}"),
         :ok <- require_present(request[:model], "no model selected") do
      attempt(request, config, on_event, 1)
    end
  end

  defp require_present(value, message) when value in [nil, ""],
    do: {:error, Error.new(:config, message)}

  defp require_present(_value, _message), do: :ok

  defp attempt(request, config, on_event, attempt) do
    request
    |> ChatCompletions.stream(config, on_event)
    |> after_attempt(request, config, on_event, attempt)
  end

  defp after_attempt({:error, %Error{} = error} = failed, request, config, on_event, attempt) do
    case Retry.decide(error, attempt, config, &:rand.uniform/1) do
      {:retry, delay} ->
        on_event.({:retry, attempt, delay, error})
        Process.sleep(delay)
        attempt(request, config, on_event, attempt + 1)

      :give_up ->
        failed
    end
  end

  defp after_attempt(result, _request, _config, _on_event, _attempt), do: result
end
