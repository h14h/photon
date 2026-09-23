defmodule PhotonNode.EventLogTest do
  use ExUnit.Case, async: true

  alias PhotonNode.EventLog

  test "numbers events by line and reads from an offset" do
    id = "log-#{System.unique_integer([:positive])}"
    assert EventLog.count(id) == 0
    assert EventLog.append(id, %{"n" => 0}) == 0
    assert EventLog.append(id, %{"n" => 1}) == 1
    assert EventLog.append(id, %{"n" => 2}) == 2
    assert EventLog.read_from(id, 1) == [{1, %{"n" => 1}}, {2, %{"n" => 2}}]
    assert EventLog.count(id) == 3
    EventLog.delete(id)
    assert EventLog.count(id) == 0
  end

  test "refuses ids that could escape the log directory, without crashing" do
    pid = Process.whereis(EventLog)
    assert_raise ArgumentError, fn -> EventLog.append("../etc", %{}) end
    assert_raise ArgumentError, fn -> EventLog.read_from("a/b", 0) end
    assert Process.whereis(EventLog) == pid
  end
end
