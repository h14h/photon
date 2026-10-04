defmodule PhotonCore.LLM.RetryTest do
  use PhotonCore.Case, async: true

  # Jitter is `random.(n)` with `n` a quarter of the backoff: these pick its
  # smallest and largest values.
  defp least(_n), do: 1
  defp most(n), do: n

  defp retryable(fields \\ []), do: Error.new(:transport, "dropped", [retryable: true] ++ fields)

  describe "decide/4" do
    test "retries a retryable error while attempts remain, six in all by default" do
      assert {:retry, _} = Retry.decide(retryable(), 1, %{}, &least/1)
      assert {:retry, _} = Retry.decide(retryable(), 5, %{}, &least/1)
      assert :give_up = Retry.decide(retryable(), 6, %{}, &least/1)
    end

    test "takes the attempt limit from the config" do
      assert :give_up = Retry.decide(retryable(), 1, %{max_attempts: 1}, &least/1)
      assert {:retry, _} = Retry.decide(retryable(), 9, %{max_attempts: 10}, &least/1)
    end

    test "never retries an error that isn't retryable" do
      error = Error.new(:http, "bad key", status: 401)
      assert :give_up = Retry.decide(error, 1, %{}, &least/1)
    end
  end

  describe "delay/4" do
    test "doubles from one second, capped at 30 seconds" do
      for {attempt, backoff} <- [{1, 1_000}, {2, 2_000}, {3, 4_000}, {5, 16_000}, {6, 30_000}] do
        assert Retry.delay(retryable(), attempt, %{}, &least/1) == backoff + 1
      end
    end

    test "adds up to a quarter of the backoff as jitter" do
      assert Retry.delay(retryable(), 3, %{}, &most/1) == 4_000 + 1_000
      assert Retry.delay(retryable(), 1, %{retry_base_ms: 2}, &most/1) == 2 + 1
    end

    test "starts from the config's retry_base_ms" do
      assert Retry.delay(retryable(), 2, %{retry_base_ms: 10}, &least/1) == 21
    end

    test "uses the provider's retry_after instead, capped at two minutes" do
      assert Retry.delay(retryable(retry_after: 0), 4, %{}, &most/1) == 0
      assert Retry.delay(retryable(retry_after: 7_000), 1, %{}, &most/1) == 7_000
      assert Retry.delay(retryable(retry_after: 600_000), 1, %{}, &most/1) == 120_000
    end
  end
end
