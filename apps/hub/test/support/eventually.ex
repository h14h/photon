defmodule Photon.Eventually do
  @moduledoc """
  Waiting on things `assert_receive` can't see, such as OS processes: call
  a check until it returns something truthy, for at most `timeout_ms`, and
  return that. No sleeping: each check (a `System.cmd/3`, say) takes long
  enough to pace the loop, and the deadline bounds it. This is the book's
  `Stream.repeatedly |> Enum.find` "eventually", with a deadline instead of
  a count.
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  @doc "The first truthy result of `check`, or nil if there is none before the deadline."
  def eventually(check, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    attempts =
      Stream.repeatedly(fn -> {check.(), System.monotonic_time(:millisecond) > deadline} end)

    attempts
    |> Enum.find_value(fn
      {result, _late} when result not in [nil, false] -> result
      {_result, true = _late} -> {:timeout}
      {_result, false} -> nil
    end)
    |> case do
      {:timeout} -> nil
      result -> result
    end
  end
end
