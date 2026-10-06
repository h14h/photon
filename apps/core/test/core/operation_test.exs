defmodule PhotonCore.OperationTest do
  use PhotonCore.Case, async: true

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
    assert "op_" <> _ = op["id"]
    refute op["id"] == Operation.new("shell", 1, %{})["id"]
  end

  test "new/5 takes the ID, so the same arguments give the same operation" do
    op = Operation.new("op_abc", "shell", 1, %{"input" => %{}}, 400)

    assert op == %{
             "id" => "op_abc",
             "type" => "shell",
             "version" => 1,
             "status" => "ready",
             "max_output_length" => 400,
             "state" => %{"input" => %{}}
           }

    assert op == Operation.new("op_abc", "shell", 1, %{"input" => %{}}, 400)
  end

  test "statuses lists the terminal ones last" do
    assert Operation.statuses() == ~w(ready awaiting canceling completed failed canceled)
    assert Operation.terminal_statuses() == ~w(completed failed canceled)
  end
end
