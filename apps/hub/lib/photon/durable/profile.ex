defmodule Photon.Durable.Profile do
  @moduledoc """
  What a conversation runs with, resolved at every use so settings changes
  apply to the next request:

    * `llm/1` - `%{config: PhotonCore.LLM config, model: id, reasoning: level | nil}`,
      and optionally `:stream`, a function that runs the request in place
      of `PhotonCore.LLM.stream/3` (same arguments and result)
    * `system_prompt/1` - kept stable between requests so provider prompt
      caches stay warm
    * `tools/1` - `Photon.Durable.Tool` modules
    * `workdir/1` (optional) - the directory its tool calls work in on
      each machine, relative to the machine's workspace; nil (or no
      callback) for the workspace itself. Tools see it as
      `Photon.Durable.ToolAPI`'s `workdir`. It must not change while a
      call runs, since a call rerun after a restart asks again.
  """

  alias Photon.Durable.Conversation

  @callback llm(Conversation.t()) :: %{
              required(:config) => map(),
              required(:model) => String.t(),
              required(:reasoning) => String.t() | nil,
              optional(:cache_key) => String.t(),
              optional(:stream) => (map(), map(), (term() -> term()) ->
                                      {:ok, map()} | {:error, term()})
            }
  @callback system_prompt(Conversation.t()) :: String.t()
  @callback tools(Conversation.t()) :: [module()]
  @callback workdir(Conversation.t()) :: String.t() | nil

  @optional_callbacks workdir: 1
end
