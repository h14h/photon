defmodule PhotonNode.Executor.RulesTest do
  @moduledoc """
  The executor's decisions: every case of `on_start/3`, `on_scan/2`,
  `down/3` and `on_unjournaled/1`, each with the journal entry's `cancel` flag false and true.
  """

  use PhotonNode.Case, async: true

  alias PhotonNode.Executor.Rules

  defp entry(status, cancel) do
    op = shell_op() |> Map.put("status", status)
    %{"op" => op, "cancel" => cancel}
  end

  describe "on_start/3" do
    test "an unjournaled operation runs only if the hub hasn't seen it" do
      for running <- [false, true] do
        assert Rules.on_start(nil, false, running) == :run
        assert Rules.on_start(nil, true, running) == :lost
      end
    end

    test "a finished operation is resent, never canceled or run" do
      for status <- Operation.terminal_statuses(),
          cancel <- [false, true],
          known <- [false, true],
          running <- [false, true] do
        assert Rules.on_start(entry(status, cancel), known, running) == {:resend, false}
      end
    end

    test "a running operation is resent, and canceled again if its entry says so" do
      for status <- ~w(ready awaiting canceling),
          cancel <- [false, true],
          known <- [false, true] do
        assert Rules.on_start(entry(status, cancel), known, true) == {:resend, cancel}
      end
    end

    test "an unfinished operation nothing runs is resumed, and canceled if its entry says so" do
      for status <- ~w(ready awaiting canceling),
          cancel <- [false, true],
          known <- [false, true] do
        assert Rules.on_start(entry(status, cancel), known, false) == {:resume, cancel}
      end
    end
  end

  describe "on_scan/2" do
    test "a finished operation is skipped until its ack" do
      for status <- Operation.terminal_statuses(),
          cancel <- [false, true],
          running <- [false, true] do
        assert Rules.on_scan(entry(status, cancel), running) == :skip
      end
    end

    test "a running operation is asked to resend, and canceled if its entry says so" do
      for cancel <- [false, true] do
        assert Rules.on_scan(entry("awaiting", cancel), true) == {:resend, cancel}
      end
    end

    test "an unfinished operation nothing runs is resumed, and canceled if its entry says so" do
      for status <- ~w(ready awaiting canceling), cancel <- [false, true] do
        assert Rules.on_scan(entry(status, cancel), false) == {:resume, cancel}
      end
    end
  end

  describe "down/3" do
    test "a finished operation's exit is ignored" do
      for status <- Operation.terminal_statuses(),
          cancel <- [false, true],
          reason <- [:normal, :killed],
          restarted <- [false, true] do
        assert Rules.down(entry(status, cancel), reason, restarted) == :ignore
      end
    end

    test "an exit with no journal entry is ignored" do
      assert Rules.down(nil, :killed, false) == :ignore
    end

    test "a clean exit before the result restarts once, canceled if the entry says so" do
      for reason <- [:normal, :shutdown, :noproc], cancel <- [false, true] do
        assert Rules.down(entry("awaiting", cancel), reason, false) == {:restart, cancel}
      end
    end

    test "a second clean exit fails the operation" do
      for cancel <- [false, true] do
        assert Rules.down(entry("awaiting", cancel), :normal, true) ==
                 {:fail, "the operation process exited: normal"}
      end
    end

    test "a crash fails the operation" do
      for cancel <- [false, true], restarted <- [false, true] do
        assert Rules.down(entry("ready", cancel), :killed, restarted) ==
                 {:fail, "the operation process exited: killed"}

        assert {:fail, "the operation process exited: " <> _} =
                 Rules.down(entry("awaiting", cancel), {:badarg, []}, restarted)
      end
    end
  end

  describe "on_unjournaled/1" do
    test "a ready entry is removed, since a resume would start the operation" do
      for cancel <- [false, true],
          do: assert(Rules.on_unjournaled(entry("ready", cancel)) == :remove)
    end

    test "a later entry, or none, is kept" do
      for status <- ~w(awaiting canceling completed failed canceled),
          cancel <- [false, true],
          do: assert(Rules.on_unjournaled(entry(status, cancel)) == :keep)

      assert Rules.on_unjournaled(nil) == :keep
    end
  end
end
