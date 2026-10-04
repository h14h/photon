defmodule PhotonCore.LLM.HTTPError do
  @moduledoc """
  Reads a failed model request (a status other than 200) into a
  `PhotonCore.LLM.Error`, as a pure function.
  """

  use Boundary, type: :strict, deps: [PhotonCore.LLM.Error, Jason]

  alias PhotonCore.LLM.Error

  # Codes that mean the user's plan or the app's share of it is spent, so
  # waiting a moment won't help.
  @spent ~w(subscription_sharing_usage_limit_exceeded insufficient_quota usage_limit_reached)

  # What Sign in with ChatGPT's own codes mean, said for the person reading it.
  @explained %{
    "subscription_sharing_usage_limit_exceeded" =>
      "Photon has used its share of your ChatGPT plan for now. " <>
        "Check your usage and Photon's limit at https://chatgpt.com/settings/usage.",
    "subscription_sharing_user_not_eligible" =>
      "This ChatGPT account's plan can't be used in other apps like Photon.",
    "subscription_sharing_usage_unavailable" =>
      "ChatGPT couldn't check your plan's usage just now."
  }

  @doc """
  The error for a request answered with `status`: the provider's message
  from `body` when it sent JSON, else the start of the body. Timeouts,
  conflicts, rate limits and server errors are retryable, except a 429 that
  says the plan's usage is spent; `retry_after` is read from the
  `retry-after` header's values (whole seconds, not negative; anything else
  is ignored).
  """
  @spec from_response(non_neg_integer(), String.t(), [String.t()]) :: Error.t()
  def from_response(status, body, retry_after_values) do
    decoded = Jason.decode(body)
    message = explain(code(decoded)) || decoded |> message(body) |> or_no_details()

    Error.new(:http, message,
      status: status,
      retryable: retryable?(status, code(decoded)),
      retry_after: retry_after_ms(retry_after_values)
    )
  end

  defp message({:ok, %{"error" => %{"message" => message}}}, _body) when is_binary(message),
    do: message

  defp message({:ok, %{"error" => message}}, _body) when is_binary(message), do: message
  defp message({:ok, %{"message" => message}}, _body) when is_binary(message), do: message
  defp message({:ok, %{"detail" => detail}}, _body) when is_binary(detail), do: detail
  defp message(_decoded, body), do: body |> String.trim() |> String.slice(0, 500)

  @doc "What an error code means, said for a person, when it's one of ChatGPT's own; else nil."
  @spec explain(term()) :: String.t() | nil
  def explain(code), do: Map.get(@explained, code)

  defp code({:ok, %{"error" => %{"code" => code}}}) when is_binary(code), do: code
  defp code({:ok, %{"error" => %{"type" => type}}}) when is_binary(type), do: type
  defp code(_decoded), do: nil

  defp or_no_details(""), do: "no details"
  defp or_no_details(message), do: message

  defp retryable?(429, code) when code in @spent, do: false
  defp retryable?(status, _code), do: status in [408, 409, 425, 429] or status >= 500

  defp retry_after_ms([value | _]), do: value |> Integer.parse() |> whole_seconds_in_ms()
  defp retry_after_ms([]), do: nil

  # A negative value isn't a wait anyone can honor (and `Process.sleep/1`
  # raises on it), so it counts as absent, like any other malformed value.
  defp whole_seconds_in_ms({seconds, ""}) when seconds >= 0, do: seconds * 1000
  defp whole_seconds_in_ms(_not_whole_seconds), do: nil
end
