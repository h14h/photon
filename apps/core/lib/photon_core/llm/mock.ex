defmodule PhotonCore.LLM.Mock do
  @moduledoc """
  A scripted stand-in for a model, so the hub's assistant runs end to end
  without a ChatGPT sign-in and tests are deterministic.

  The config's `:script` is a module with `respond(request)` returning an
  assistant message (see `PhotonCore.Message`), or `{:error, message}`. The
  answer is streamed back word by word like a real one, then its tool calls.
  Usage is estimated at four bytes per token. A script's error comes back as
  a non-retryable HTTP 500.

  This is the provider adapter `PhotonCore.LLM` uses for `"mock"`; the
  helpers below are for writing scripts.
  """

  use Boundary, type: :strict, deps: [PhotonCore, PhotonCore.LLM.Error, Jason]

  alias PhotonCore.LLM
  alias PhotonCore.LLM.Error
  alias PhotonCore.Message

  @callback respond(request :: LLM.request()) :: Message.t() | {:error, String.t()}

  @doc "Answers `request` with the config's script. See `PhotonCore.LLM.stream/3`."
  @spec stream(LLM.request(), LLM.config(), LLM.on_event()) ::
          {:ok, LLM.response()} | {:error, Error.t()}
  def stream(request, config, on_event) do
    script = config[:script] || raise ArgumentError, "the mock provider needs a :script"
    request |> script.respond() |> answer(request, on_event)
  end

  defp answer({:error, message}, _request, _on_event),
    do: {:error, Error.new(:http, message, status: 500)}

  defp answer(message, request, on_event) do
    message = Map.merge(empty_answer(), message)
    message |> events() |> Enum.each(on_event)
    {:ok, response(request, message)}
  end

  defp empty_answer,
    do: %{"role" => "assistant", "content" => [], "reasoning" => nil, "tool_calls" => []}

  defp events(message),
    do: text_events(Message.text_of(message)) ++ tool_call_events(message["tool_calls"])

  defp text_events(text),
    do: for(word <- String.split(text, ~r/(?<= )/), word != "", do: {:text, word})

  defp tool_call_events(calls) do
    calls
    |> Enum.with_index()
    |> Enum.map(fn {call, index} -> {:tool_call, index, call["name"], call["arguments"]} end)
  end

  defp response(request, message) do
    %{
      "message" => message,
      "stop" => stop_reason(message["tool_calls"]),
      "usage" => %{
        "input" => input_tokens(request),
        "cached" => 0,
        "output" => tokens(byte_size(Jason.encode!(message))),
        "reasoning" => 0
      },
      "model" => "mock-model"
    }
  end

  defp stop_reason([]), do: "end_turn"
  defp stop_reason(_calls), do: "tool_use"

  defp input_tokens(request) do
    tokens(byte_size(Jason.encode!(request[:messages] || [])) + byte_size(request[:system] || ""))
  end

  defp tokens(bytes), do: div(bytes, 4)

  ## Helpers for scripts

  @doc "A tool call with JSON-encoded arguments and a fresh ID (from the clock and RNG)."
  @spec call(String.t(), map()) :: Message.tool_call()
  def call(name, args) do
    %{"id" => "call_" <> PhotonCore.ID.new(), "name" => name, "arguments" => Jason.encode!(args)}
  end

  @doc "The text of the latest user message in a request."
  @spec last_user_text(LLM.request()) :: String.t()
  def last_user_text(request) do
    request[:messages]
    |> Enum.filter(&(&1["role"] == "user"))
    |> List.last()
    |> text_or_empty()
  end

  defp text_or_empty(nil), do: ""
  defp text_or_empty(message), do: Message.text_of(message)

  @doc """
  Messages after the latest user message: what the model has done since it
  was last asked something.
  """
  @spec since_user(LLM.request()) :: [Message.t()]
  def since_user(request) do
    request[:messages]
    |> Enum.reverse()
    |> Enum.take_while(&(&1["role"] != "user"))
    |> Enum.reverse()
  end
end
