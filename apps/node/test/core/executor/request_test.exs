defmodule PhotonNode.Executor.RequestTest do
  @moduledoc """
  The executor's request core: an `op.start` into a runnable operation,
  the snapshots for operations the node answers without running, and
  fitting a snapshot's JSON to the frame budget.
  """

  use PhotonNode.Case, async: true

  alias PhotonCore.Operation.Wire
  alias PhotonNode.Executor.Request

  @facts %{shell: "/bin/bash", ops_dir: "/data/ops", workspace: "/data/workspace"}

  defp start(kind, args), do: %{"id" => "op_1", "kind" => kind, "args" => args, "known" => false}

  defp shell(args) do
    start(
      "shell",
      Map.merge(%{"command" => "ls", "directory" => nil, "max_output_length" => 100}, args)
    )
  end

  defp image(args) do
    start(
      "view_image",
      Map.merge(%{"path" => "a.png", "directory" => nil, "max_size" => 4_999_000}, args)
    )
  end

  defp error(start), do: elem(Request.operation(start, @facts), 1)

  describe "operation/2 for shell" do
    test "fills in the shell, the ops directory and the workspace" do
      assert {:ok, op} = Request.operation(shell(%{}), @facts)

      assert %{
               "id" => "op_1",
               "type" => "shell",
               "version" => 1,
               "status" => "ready",
               "max_output_length" => 100
             } = op

      assert op["state"]["input"] == %{
               "command" => "ls",
               "shell" => "/bin/bash",
               "directory" => "/data/workspace"
             }

      assert %{"base_directory" => "/data/ops", "phase" => "", "pgid" => 0, "result" => nil} =
               op["state"]
    end

    test "a given directory wins, and a relative one is taken from the workspace" do
      {:ok, op} = Request.operation(shell(%{"directory" => "/srv/app"}), @facts)
      assert op["state"]["input"]["directory"] == "/srv/app"

      {:ok, op} = Request.operation(shell(%{"directory" => "proj"}), @facts)
      assert op["state"]["input"]["directory"] == "/data/workspace/proj"
    end

    test "bad arguments are errors" do
      assert error(shell(%{"command" => nil})) =~ ~s("command" must be a string)
      assert error(shell(%{"command" => 7})) =~ ~s("command" must be a string)
      assert error(shell(%{"command" => "a\0b"})) =~ "NUL byte"
      assert error(shell(%{"command" => String.duplicate("x", 100_001)})) =~ "over 100000 bytes"
      assert error(shell(%{"max_output_length" => 0})) =~ "from 1 to 1000000"
      assert error(shell(%{"max_output_length" => 1_000_001})) =~ "from 1 to 1000000"
      assert error(shell(%{"max_output_length" => "10"})) =~ "max_output_length"
      assert error(shell(%{"directory" => 5})) =~ ~s("directory" must be a string or null)
      assert error(shell(%{"directory" => " "})) =~ ~s("directory" is blank)
      assert error(shell(%{"directory" => "/a\0"})) =~ "NUL byte"
    end

    test "a 100,000-byte command is allowed" do
      command = String.duplicate("x", 100_000)
      assert {:ok, op} = Request.operation(shell(%{"command" => command}), @facts)
      assert op["state"]["input"]["command"] == command
    end
  end

  describe "operation/2 for view_image" do
    test "an absolute path is kept" do
      {:ok, op} = Request.operation(image(%{"path" => "/tmp/a.png"}), @facts)

      assert %{"type" => "view_image", "status" => "ready", "max_output_length" => nil} = op
      assert op["state"] == %{"path" => "/tmp/a.png", "max_size" => 4_999_000, "result" => nil}
    end

    test "a relative path joins the directory, or the workspace" do
      {:ok, op} = Request.operation(image(%{"directory" => "/srv"}), @facts)
      assert op["state"]["path"] == "/srv/a.png"

      {:ok, op} = Request.operation(image(%{"directory" => "shots"}), @facts)
      assert op["state"]["path"] == "/data/workspace/shots/a.png"

      {:ok, op} = Request.operation(image(%{}), @facts)
      assert op["state"]["path"] == "/data/workspace/a.png"
    end

    test "bad arguments are errors" do
      assert error(image(%{"path" => nil})) =~ ~s("path" must be a string)
      assert error(image(%{"path" => "  "})) =~ ~s("path" is blank)
      assert error(image(%{"path" => "a\0.png"})) =~ "NUL byte"
      assert error(image(%{"max_size" => 0})) =~ "max_size"
      assert error(image(%{"max_size" => 5_000_001})) =~ "from 1 to 5000000"
      assert error(image(%{"directory" => false})) =~ "must be a string or null"
    end
  end

  test "an unknown kind is an error, and rejected/2 makes it a failed snapshot" do
    start = start("teleport", %{})
    assert {:error, reason} = Request.operation(start, @facts)
    assert reason =~ ~s(kind "teleport")

    op = Request.rejected(start, reason)

    assert %{"id" => "op_1", "type" => "teleport", "status" => "failed"} = op
    assert op["state"]["terminal_error"] == reason
    assert {:ok, ^op} = Wire.parse_snapshot(%{"op" => op})
  end

  describe "answers without running" do
    test "lost/2 is a failed snapshot saying the machine has no record" do
      op = Request.lost("op_1", "shell")

      assert %{"id" => "op_1", "type" => "shell", "status" => "failed"} = op

      assert op["state"]["terminal_error"] ==
               "The machine has no record of this operation. It may or may not have run."

      assert {:ok, ^op} = Wire.parse_snapshot(%{"op" => op})
    end

    test "a view_image answer also carries its reason in result.error" do
      op = Request.lost("op_1", "view_image")
      assert op["state"]["result"]["error"] == op["state"]["terminal_error"]
    end

    test "never_started/1 is a canceled snapshot of an unknown type" do
      op = Request.never_started("op_9")

      assert %{"id" => "op_9", "type" => "unknown", "status" => "canceled"} = op
      assert op["state"]["terminal_error"] == "Canceled before it started."
      assert Operation.terminal?(op)
      assert {:ok, ^op} = Wire.parse_snapshot(%{"op" => op})
    end

    test "unrecorded/2 fails the ready operation and says it didn't run" do
      {:ok, ready} = Request.operation(shell(%{}), @facts)
      op = Request.unrecorded(ready, "no space left on device")

      assert op["status"] == "failed"
      assert op["state"]["input"] == ready["state"]["input"]

      assert op["state"]["terminal_error"] ==
               "The machine couldn't record the operation: no space left on device. It didn't run."

      {:ok, image} = Request.operation(image(%{}), @facts)
      image = Request.unrecorded(image, "read-only file system")
      assert image["state"]["result"]["error"] =~ "read-only file system"
    end
  end

  describe "fit/2" do
    @budget 6_000_000
    @out_path "/data/ops/op_1/out"
    @err_path "/data/ops/op_1/err"

    defp finished(out, err, sizes, truncated) do
      {:ok, op} =
        Request.operation(
          shell(%{"command" => String.duplicate("x", 100_000), "max_output_length" => 1_000_000}),
          @facts
        )

      Operation.advance(op, "completed", %{
        "out_path" => @out_path,
        "err_path" => @err_path,
        "result" => %{
          "out" => out,
          "err" => err,
          "out_size" => elem(sizes, 0),
          "err_size" => elem(sizes, 1),
          "exit_code" => 0
        },
        "out_truncated" => truncated,
        "err_truncated" => truncated
      })
    end

    defp encoded_size(op), do: op |> Jason.encode!() |> byte_size()

    # The marker's byte count, and the bytes kept around it.
    defp marker(text, path) do
      [marker, count] =
        Regex.run(~r/\.\.\.(\d+) bytes truncated; complete output in #{path}\.\.\./, text)

      {String.to_integer(count), byte_size(text) - byte_size(marker)}
    end

    test "a worst-case snapshot fits and keeps both markers and paths" do
      nuls = :binary.copy(<<0>>, 1_000_000)
      out = Output.truncated(nuls, nuls, 5_000_000, 1_000_000, @out_path)
      err = Output.truncated(nuls, nuls, 3_000_000, 1_000_000, @err_path)
      op = finished(out, err, {5_000_000, 3_000_000}, true)
      assert encoded_size(op) > 12_000_000

      fitted = Request.fit(op, @budget)
      result = fitted["state"]["result"]

      assert encoded_size(fitted) <= @budget
      assert {out_skipped, out_kept} = marker(result["out"], @out_path)
      assert {err_skipped, err_kept} = marker(result["err"], @err_path)
      assert out_skipped + out_kept == 5_000_000
      assert err_skipped + err_kept == 3_000_000
      assert out_kept > 400_000 and err_kept > 400_000

      for text <- [result["out"], result["err"]] do
        assert String.starts_with?(text, <<0>>)
        assert String.ends_with?(text, <<0>>)
        assert length(Regex.scan(~r/bytes truncated/, text)) == 1
      end

      assert fitted["state"]["input"] == op["state"]["input"]
      assert fitted["state"]["out_truncated"] and fitted["state"]["err_truncated"]
    end

    test "untruncated output that is over the budget gets a marker with its path" do
      nuls = :binary.copy(<<0>>, 1_000_000)
      op = finished(nuls, "fine", {1_000_000, 4}, false)

      fitted = Request.fit(op, 3_000_000)
      result = fitted["state"]["result"]

      assert encoded_size(fitted) <= 3_000_000
      assert {skipped, kept} = marker(result["out"], @out_path)
      assert skipped + kept == 1_000_000
      assert result["err"] == "fine"
      assert fitted["state"]["out_truncated"]
      refute fitted["state"]["err_truncated"]
    end

    test "a long terminal error is cut around a marker without a path" do
      {:ok, op} = Request.operation(shell(%{}), @facts)
      op = Operation.fail(op, String.duplicate("é", 600_000))

      fitted = Request.fit(op, 500_000)
      error = fitted["state"]["terminal_error"]

      assert encoded_size(fitted) <= 500_000
      assert [_, count] = Regex.run(~r/\.\.\.(\d+) bytes truncated\.\.\./, error)

      assert String.to_integer(count) + byte_size(error) -
               byte_size("...#{count} bytes truncated...") == 1_200_000

      assert String.starts_with?(error, "é") and String.ends_with?(error, "é")
    end

    test "a snapshot under the budget comes back unchanged" do
      op = finished("hello\n", "", {6, 0}, false)
      assert Request.fit(op, @budget) == op

      image = Request.lost("op_1", "view_image")
      assert Request.fit(image, @budget) == image
    end
  end
end
