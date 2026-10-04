defmodule PhotonCore.LLM.Error do
  @moduledoc """
  Why a model request failed. `retryable` marks failures worth another
  attempt (rate limits, server errors, dropped connections); `retry_after`
  is the provider's requested delay in milliseconds, when it gave one.

  Build one with `new/3`, which requires a kind and a message.
  """

  # Data: why a request failed. Its own top-level boundary, so functional
  # cores that record failures depend on it and not on the client.
  use Boundary, top_level?: true, type: :strict, deps: []

  @enforce_keys [:kind, :message]
  defexception [:kind, :status, :message, retryable: false, retry_after: nil]

  @type kind :: :http | :transport | :stream | :config

  @type t :: %__MODULE__{
          kind: kind(),
          status: non_neg_integer() | nil,
          message: String.t(),
          retryable: boolean(),
          retry_after: non_neg_integer() | nil
        }

  @doc """
  An error of `kind` with `message`. `fields` sets the rest: `:status`,
  `:retryable` (default `false`) and `:retry_after`.
  """
  @spec new(kind(), String.t(), keyword()) :: t()
  def new(kind, message, fields \\ []) do
    struct!(__MODULE__, [kind: kind, message: message] ++ fields)
  end

  @impl true
  def message(%__MODULE__{status: nil, message: message}), do: message
  def message(%__MODULE__{status: status, message: message}), do: "HTTP #{status}: #{message}"

  @doc "A serializable summary, for transcripts."
  @spec to_map(t()) :: %{String.t() => String.t() | non_neg_integer() | nil}
  def to_map(%__MODULE__{} = e) do
    %{"kind" => to_string(e.kind), "status" => e.status, "message" => message(e)}
  end
end
