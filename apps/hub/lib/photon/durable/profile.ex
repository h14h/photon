defmodule Photon.Durable.Profile do
  @moduledoc """
  What a conversation runs with, resolved at every use so settings changes
  apply to the next request:

    * `llm/1` - `%{config: PhotonCore.LLM config, model: id, reasoning: level | nil}`
    * `system_prompt/1` - kept stable between requests so provider prompt
      caches stay warm
    * `tools/1` - `Photon.Durable.Tool` modules
  """

  alias Photon.Durable.Conversation

  @callback llm(Conversation.t()) :: %{
              required(:config) => map(),
              required(:model) => String.t(),
              required(:reasoning) => String.t() | nil,
              optional(:cache_key) => String.t()
            }
  @callback system_prompt(Conversation.t()) :: String.t()
  @callback tools(Conversation.t()) :: [module()]
end
