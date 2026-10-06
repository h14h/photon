defmodule Photon.MachineTools.WaitTest do
  @moduledoc "How a machine tool call waits for its op: op IDs, checks and the offline limit."

  use Photon.Case, async: true

  alias Photon.MachineTools.Wait

  @limits %{check_ms: 60_000, offline_limit_ms: 600_000}
  @now 1_000_000_000

  defp state(offline_since),
    do: %{"op_id" => "op_1", "machine" => "mm1", "offline_since" => offline_since}

  test "op_id/1 derives the op ID from the tool task's ID" do
    assert Wait.op_id("t_06abc") == "op_06abc"
  end

  describe "first/3" do
    test "online: check after the interval, not offline" do
      assert Wait.first(true, @now, @limits) == {@now + 60_000, nil}
    end

    test "offline: the first sighting sets offline_since" do
      assert Wait.first(false, @now, @limits) == {@now + 60_000, @now}
    end

    test "offline: never wakes past the limit" do
      assert Wait.first(false, @now, %{check_ms: 60_000, offline_limit_ms: 5}) == {@now + 5, @now}
    end
  end

  describe "next/4" do
    test "parks until the next check while online, and clears offline_since" do
      assert Wait.next(state(@now - 30_000), true, @now, @limits) ==
               {:park, @now + 60_000, state(nil)}
    end

    test "the first offline sighting sets offline_since" do
      assert Wait.next(state(nil), false, @now, @limits) == {:park, @now + 60_000, state(@now)}
    end

    test "keeps offline_since while the machine stays offline" do
      since = @now - 120_000
      assert Wait.next(state(since), false, @now, @limits) == {:park, @now + 60_000, state(since)}
    end

    test "never sets a check past the limit" do
      since = @now - 580_000

      assert Wait.next(state(since), false, @now, @limits) ==
               {:park, since + 600_000, state(since)}

      for elapsed <- [0, 1, 59_999, 540_000, 599_999] do
        since = @now - elapsed
        {:park, until, _state} = Wait.next(state(since), false, @now, @limits)
        assert until <= since + 600_000
      end
    end

    test "gives up once the machine has been offline for the limit" do
      assert Wait.next(state(@now - 600_000), false, @now, @limits) == :give_up
      assert Wait.next(state(@now - 900_000), false, @now, @limits) == :give_up
    end

    test "with a zero limit, gives up at the first offline sighting" do
      assert Wait.next(state(nil), false, @now, %{check_ms: 10, offline_limit_ms: 0}) == :give_up
    end
  end

  describe "offline_message/3" do
    test "says the command didn't run only when it was never pushed and never confirmed" do
      for online <- [false, true] do
        facts = %{pushed: false, confirmed: false, online: online}

        assert Wait.offline_message("mm1", facts, 600_000) ==
                 "mm1 has been offline for 10 minutes, so the command didn't run. " <>
                   "It won't run when mm1 comes back."
      end
    end

    test "hedges when the op was pushed or confirmed and the machine is still offline" do
      for {pushed, confirmed} <- [{true, false}, {false, true}, {true, true}] do
        facts = %{pushed: pushed, confirmed: confirmed, online: false}

        assert Wait.offline_message("mm1", facts, 600_000) ==
                 "mm1 went offline after the command was sent and hasn't been back for 10 minutes. " <>
                   "The command may have run, and may still be running there; " <>
                   "if it is, it will be stopped when mm1 reconnects."
      end
    end

    test "hedges when the op was pushed or confirmed and the machine just came back" do
      for {pushed, confirmed} <- [{true, false}, {false, true}, {true, true}] do
        facts = %{pushed: pushed, confirmed: confirmed, online: true}

        assert Wait.offline_message("mm1", facts, 600_000) ==
                 "mm1 was offline for 10 minutes and has just come back. " <>
                   "The command may have started; it is being stopped."
      end
    end

    test "names the limit it was given" do
      facts = %{pushed: false, confirmed: false, online: false}
      assert Wait.offline_message("mm1", facts, 60_000) =~ "offline for 1 minute,"
      assert Wait.offline_message("mm1", facts, 90_000) =~ "offline for 90 seconds,"
      assert Wait.offline_message("mm1", facts, 1) =~ "offline for 1 millisecond,"
      assert Wait.offline_message("mm1", facts, 250) =~ "offline for 250 milliseconds,"
    end
  end
end
