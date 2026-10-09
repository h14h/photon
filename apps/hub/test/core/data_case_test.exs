defmodule Photon.DataCaseTest do
  @moduledoc "The test support's own waits."

  use ExUnit.Case, async: true

  alias Photon.DataCase

  test "await_change/3 returns the first commit that matches" do
    send(self(), {:durable, "c_1", %{n: 1}})
    send(self(), {:durable, "c_1", %{n: 2}})

    assert DataCase.await_change("c_1", &(&1.n == 2), 1_000) == %{n: 2}
  end

  test "await_change/3 gives up at its deadline, however many other commits are queued" do
    Enum.each(1..1_000, &send(self(), {:durable, "c_1", %{n: &1}}))

    # Each commit that doesn't match takes a while, so the queue outlasts
    # the 5 ms deadline; the wait must stop reading it there.
    slow_no = fn _changes ->
      Process.put(:seen, Process.get(:seen, 0) + 1)
      Enum.reduce(1..20_000, 0, &(&1 + &2))
      false
    end

    assert_raise ExUnit.AssertionError, ~r/no matching commit for c_1/, fn ->
      DataCase.await_change("c_1", slow_no, 5)
    end

    assert Process.get(:seen) < 1_000
  end
end
