defmodule PhotonNode.Harness.OperationTest do
  use PhotonNode.Case, async: true

  test "advance sets the status and merges the state" do
    op = shell_op() |> Operation.advance("awaiting", %{"phase" => "process", "pgid" => 7})

    assert op["status"] == "awaiting"
    assert %{"phase" => "process", "pgid" => 7, "input" => %{"command" => "true"}} = op["state"]
    refute Operation.terminal?(op)
  end

  test "fail records why" do
    op = Operation.fail(shell_op(), "it broke")

    assert %{"status" => "failed", "state" => %{"terminal_error" => "it broke"}} = op
    assert Operation.terminal?(op)
  end

  test "new operations are ready, with a fresh ID" do
    op = Operation.new("shell", 1, %{})
    assert %{"status" => "ready", "version" => 1, "max_output_length" => nil} = op
    refute op["id"] == Operation.new("shell", 1, %{})["id"]
  end
end
