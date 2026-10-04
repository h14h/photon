defmodule PhotonCore.LLM.Retry do
  @moduledoc """
  The retry policy for model requests: whether a failed attempt is worth
  another, and how long to wait first.

  Only errors marked `retryable` are retried, up to the config's
  `:max_attempts` attempts in all (default 6). The wait is the provider's
  `retry_after` when it gave one, capped at 2 minutes. Otherwise it doubles
  from the config's `:retry_base_ms` (1s, 2s, 4s, ...), capped at 30s, plus
  up to 25% jitter.

  Pure: the jitter's randomness is an argument. `PhotonCore.LLM` passes
  `:rand.uniform/1` and does the waiting.
  """

  use Boundary, type: :strict, deps: [PhotonCore.LLM.Error]

  alias PhotonCore.LLM.Error

  @default_max_attempts 6
  @default_base_ms 1_000
  @max_backoff_ms 30_000
  @max_retry_after_ms 120_000

  @typedoc "Picks an integer in `1..n`, as `:rand.uniform/1` does."
  @type random :: (pos_integer() -> pos_integer())

  @doc """
  What to do after attempt number `attempt` (counting from 1) failed with
  `error`: `{:retry, delay_ms}` or `:give_up`.
  """
  @spec decide(Error.t(), pos_integer(), map(), random()) ::
          {:retry, non_neg_integer()} | :give_up
  def decide(%Error{retryable: true} = error, attempt, config, random) do
    if attempt < max_attempts(config),
      do: {:retry, delay(error, attempt, config, random)},
      else: :give_up
  end

  def decide(%Error{} = _not_retryable, _attempt, _config, _random), do: :give_up

  @doc "How long to wait after attempt number `attempt` failed with `error`."
  @spec delay(Error.t(), pos_integer(), map(), random()) :: non_neg_integer()
  def delay(%Error{retry_after: ms}, _attempt, _config, _random) when is_integer(ms),
    do: min(ms, @max_retry_after_ms)

  def delay(_error, attempt, config, random) do
    backoff = backoff(attempt, config[:retry_base_ms] || @default_base_ms)
    spread = max(div(backoff, 4), 1)
    backoff + random.(spread)
  end

  @doc "Attempts allowed in all, failed ones included."
  @spec max_attempts(map()) :: pos_integer()
  def max_attempts(config), do: config[:max_attempts] || @default_max_attempts

  defp backoff(attempt, base_ms), do: min(base_ms * Integer.pow(2, attempt - 1), @max_backoff_ms)
end
