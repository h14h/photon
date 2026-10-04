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
    * `:max_tokens` - optional output cap (ChatGPT doesn't accept one)
    * `:cache_key` - what the request continues (a conversation or session
      ID), so the provider can cache its history between turns

  A config says where to send it:

    * `:provider` - `"chatgpt"` (the Responses API with a Sign in with
      ChatGPT token; the hub), `"relay"` (the hub's model relay; nodes) or
      `"mock"` (a scripted model; tests)
    * `:base_url` - where the provider is
    * `:api_key` - the bearer token: the ChatGPT access token, or the
      node's key for the relay
    * `:problem` - for `"chatgpt"` without a token, why there is none (the
      error says so instead of "not signed in")
    * `:headers` - extra request headers
    * `:script` - for `"mock"`, the module that answers (see `PhotonCore.LLM.Mock`)
    * `:max_attempts` - attempts for retryable failures (default 6)
    * `:retry_base_ms` - the first retry's backoff (default 1000)
    * `:receive_timeout` - milliseconds to wait for data (default 180000)
    * `:extra_body` - fields merged into the request body
    * `:hosted_tools` - tools the API runs itself, e.g.
      `[%{"type" => "web_search"}]` (Responses only)
    * `:req_options` - extra `Req` options, e.g. a test plug

  Keys it doesn't know are ignored.

  `on_event` receives `{:text, delta}`, `{:reasoning, delta}`,
  `{:tool_call, index, name, args_delta}` and `{:web_search, id, action}`
  (a search a hosted tool ran: `action` is nil when it starts, then what it
  did, e.g. `%{"type" => "search", "query" => ...}`) while the answer
  streams, and
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

  # The model client: this API in front of the HTTP adapters and the mock.
  use Boundary,
    top_level?: true,
    type: :strict,
    deps: [PhotonCore, PhotonCore.LLM.Error, Jason, Req],
    exports: [Mock, MockAgent, Relay, Responses]

  alias PhotonCore.LLM.{Error, Mock, Relay, Responses, Retry}
  alias PhotonCore.Message

  @typedoc "A model request; see the moduledoc."
  @type request :: %{
          optional(:model) => String.t() | nil,
          optional(:system) => String.t() | nil,
          optional(:messages) => [Message.t()],
          optional(:tools) => [map()],
          optional(:reasoning) => String.t() | nil,
          optional(:max_tokens) => pos_integer() | nil,
          optional(:cache_key) => String.t() | nil
        }

  @typedoc "Where and how to send a request; see the moduledoc."
  @type config :: %{
          optional(:provider) => String.t() | nil,
          optional(:base_url) => String.t() | nil,
          optional(:api_key) => String.t() | nil,
          optional(:problem) => String.t() | nil,
          optional(:headers) => [{String.t(), String.t()}],
          optional(:script) => module() | nil,
          optional(:max_attempts) => pos_integer(),
          optional(:retry_base_ms) => non_neg_integer(),
          optional(:receive_timeout) => timeout(),
          optional(:extra_body) => map(),
          optional(:hosted_tools) => [map()],
          optional(:req_options) => keyword(),
          optional(atom()) => term()
        }

  @typedoc "What `on_event` receives while a request runs."
  @type event ::
          {:text, String.t()}
          | {:reasoning, String.t()}
          | {:tool_call, non_neg_integer(), String.t() | nil, String.t()}
          | {:web_search, String.t(), map() | nil}
          | {:retry, pos_integer(), non_neg_integer(), Error.t()}

  @type on_event :: (event() -> term())

  @typedoc ~s(`"message"`, `"stop"`, `"usage"` and `"model"`; see the moduledoc.)
  @type response :: %{optional(String.t()) => term()}

  @doc "Runs `request` against `config`'s provider. See the moduledoc."
  @spec stream(request(), config(), on_event()) :: {:ok, response()} | {:error, Error.t()}
  def stream(request, config, on_event \\ fn _event -> :ok end)

  def stream(request, %{provider: "mock"} = config, on_event),
    do: Mock.stream(request, config, on_event)

  def stream(request, %{provider: "chatgpt"} = config, on_event) do
    with :ok <-
           require_present(config[:api_key], config[:problem] || "not signed in with ChatGPT"),
         :ok <- require_present(request[:model], "no model selected") do
      attempt(Responses, request, config, on_event, 1)
    end
  end

  def stream(request, %{provider: "relay"} = config, on_event) do
    with :ok <- require_present(config[:base_url], "no hub to relay through") do
      attempt(Relay, request, config, on_event, 1)
    end
  end

  def stream(_request, config, _on_event),
    do: {:error, Error.new(:config, "unknown model provider #{inspect(config[:provider])}")}

  defp require_present(value, message) when value in [nil, ""],
    do: {:error, Error.new(:config, message)}

  defp require_present(_value, _message), do: :ok

  defp attempt(adapter, request, config, on_event, attempt) do
    case adapter.stream(request, config, on_event) do
      {:error, %Error{} = error} = failed ->
        case Retry.decide(error, attempt, config, &:rand.uniform/1) do
          {:retry, delay} ->
            on_event.({:retry, attempt, delay, error})
            Process.sleep(delay)
            attempt(adapter, request, config, on_event, attempt + 1)

          :give_up ->
            failed
        end

      result ->
        result
    end
  end
end
