defmodule PhotonCore.Operation.ResultTest do
  use PhotonCore.Case, async: true

  alias PhotonCore.Operation
  alias PhotonCore.Operation.Result

  defp op(type, status, state),
    do: %{Operation.new("op_1", type, 1, %{}, 40_000) | "status" => status, "state" => state}

  describe "check/1" do
    test "passes what nodes send: results, failures, cancels and unset fields" do
      for op <- [
            op("shell", "completed", %{
              "out_path" => "/ops/op_1/out",
              "err_path" => "/ops/op_1/err",
              "exit_code" => nil,
              "result" => %{"out" => "hi\n", "err" => "", "exit_code" => 0, "out_size" => 3}
            }),
            op("shell", "completed", %{}),
            op("shell", "canceled", %{"terminal_error" => "canceled", "result" => %{"out" => "x"}}),
            op("shell", "failed", %{"terminal_error" => "boom", "result" => %{"error" => "boom"}}),
            op("view_image", "completed", %{
              "result" => %{"content" => "AA==", "mime" => "image/png", "path" => "/a.png"}
            }),
            op("view_image", "failed", %{"result" => %{"error" => "no such file"}}),
            op("shell", "awaiting", %{"result" => 7}),
            op("future_kind", "completed", %{"result" => 7})
          ] do
        assert Result.check(op) == :ok, inspect(op)
      end
    end

    test "names the first field that isn't what its kind promises" do
      assert Result.check(op("shell", "completed", %{"result" => 7})) ==
               {:error, "state.result must be an object"}

      assert Result.check(op("shell", "completed", %{"result" => %{"out" => ["hi"]}})) ==
               {:error, "state.result.out must be a string"}

      assert Result.check(op("shell", "completed", %{"result" => %{"exit_code" => "0"}})) ==
               {:error, "state.result.exit_code must be an integer"}

      assert Result.check(op("shell", "failed", %{"terminal_error" => %{}})) ==
               {:error, "state.terminal_error must be a string"}

      assert Result.check(op("shell", "completed", %{"out_path" => 1})) ==
               {:error, "state.out_path must be a string"}

      assert Result.check(op("view_image", "completed", %{"result" => %{"path" => %{}}})) ==
               {:error, "state.result.path must be a string"}

      assert Result.check(op("view_image", "completed", %{"result" => %{"width" => 1.5}})) ==
               {:error, "state.result.width must be an integer"}
    end
  end

  describe "accept/1" do
    test "keeps a readable snapshot as it is" do
      op = op("shell", "completed", %{"result" => %{"out" => "hi"}})
      assert Result.accept(op) == {:ok, op}
    end

    test "turns an unreadable one into a failure that says why" do
      op = op("shell", "completed", %{"result" => 7, "out_path" => "/ops/op_1/out"})

      assert {:malformed, failed, "state.result must be an object"} = Result.accept(op)
      assert failed["status"] == "failed"
      assert failed["state"]["result"] == nil
      assert failed["state"]["out_path"] == "/ops/op_1/out"

      assert failed["state"]["terminal_error"] ==
               "The machine sent a result the hub can't read (state.result must be an object)."

      assert Result.check(failed) == :ok
    end
  end
end
