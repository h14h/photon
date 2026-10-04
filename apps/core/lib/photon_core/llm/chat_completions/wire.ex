defmodule PhotonCore.LLM.ChatCompletions.Wire do
  @moduledoc false

  use Boundary, type: :strict, deps: [Jason]

  # Lenient readers for values a provider, or a node through the hub's
  # proxy, sends in Chat Completions JSON. A value of the wrong shape reads
  # as absent instead of raising. Shared by `Request` and `Response`.

  @spec list(term()) :: list()
  def list(value) when is_list(value), do: value
  def list(_value), do: []

  @spec text_or_nil(term()) :: String.t() | nil
  def text_or_nil(value) when is_binary(value), do: value
  def text_or_nil(_value), do: nil

  # Tool-call arguments are JSON text; some servers send the object itself.
  @spec arguments_text(term()) :: String.t() | nil
  def arguments_text(nil), do: nil
  def arguments_text(text) when is_binary(text), do: text
  def arguments_text(other), do: Jason.encode!(other)
end
