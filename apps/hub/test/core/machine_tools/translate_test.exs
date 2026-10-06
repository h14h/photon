defmodule Photon.MachineTools.TranslateTest do
  @moduledoc """
  Machine tool arguments to op `args`, and terminal snapshots to results
  and details. Ported from the node's `test/core/tools_test.exs`, plus the
  hub's own checks.
  """

  use Photon.Case, async: true

  alias Photon.MachineTools.Translate
  alias PhotonCore.{Operation, Output}

  @out_path "/data/ops/op_1/out"
  @err_path "/data/ops/op_1/err"

  defp shell_op(limit \\ 40_000) do
    Operation.new(
      "op_1",
      "shell",
      1,
      %{
        "input" => %{"command" => "make", "shell" => "/bin/sh", "directory" => "/work"},
        "base_directory" => "/data/ops",
        "terminal_error" => "",
        "out_path" => @out_path,
        "err_path" => @err_path,
        "result" => nil
      },
      limit
    )
  end

  defp completed(op, result, flags \\ %{}),
    do: Operation.advance(op, "completed", Map.merge(%{"result" => result}, flags))

  defp image_op(result) do
    "op_2"
    |> Operation.new("view_image", 1, %{"path" => "/work/a.png", "max_size" => 4_999_000}, nil)
    |> Operation.advance("completed", %{"result" => result})
  end

  defp image(changes \\ %{}) do
    Map.merge(
      %{
        "content" => "QQ",
        "mime" => "image/png",
        "width" => 2,
        "height" => 3,
        "path" => "/work/a.png"
      },
      changes
    )
  end

  defp text(parts), do: Message.text_of(parts)

  describe "shell_args/2" do
    test "gives the op's args, with the default limit and no directory" do
      assert Translate.shell_args(%{"machine" => "mm1", "command" => "ls -la"}, nil) ==
               {:ok, %{"command" => "ls -la", "directory" => nil, "max_output_length" => 40_000}}

      assert {:ok, %{"max_output_length" => 1}} =
               Translate.shell_args(%{"command" => "ls", "max_output_length" => 1}, nil)

      assert {:ok, %{"max_output_length" => 1_000_000}} =
               Translate.shell_args(%{"command" => "ls", "max_output_length" => 1_000_000}, nil)
    end

    test "puts the working directory in the op's args" do
      assert {:ok, %{"directory" => "garden"}} =
               Translate.shell_args(%{"command" => "ls"}, "garden")
    end

    test "refuses a limit out of range" do
      assert Translate.shell_args(%{"command" => "ls", "max_output_length" => 1_000_001}, nil) ==
               {:error, "shell argument: max_output_length must not exceed 1000000"}

      assert Translate.shell_args(%{"command" => "ls", "max_output_length" => 0}, nil) ==
               {:error, "shell argument: max_output_length must be a positive integer"}

      assert Translate.shell_args(%{"command" => "ls", "max_output_length" => "9"}, nil) ==
               {:error, "shell argument: max_output_length must be an integer"}
    end

    test "refuses a missing, blank or mistyped command" do
      for args <- [%{}, %{"command" => nil}, %{"command" => " "}] do
        assert Translate.shell_args(args, nil) ==
                 {:error, ~s(shell argument "command" must be set)}
      end

      assert Translate.shell_args(%{"command" => 3}, nil) ==
               {:error, ~s(shell argument "command" must be a string)}
    end

    test "refuses a NUL byte" do
      assert Translate.shell_args(%{"command" => "a\0b"}, nil) ==
               {:error, ~s(shell argument "command" contains a NUL byte at offset 1)}
    end

    test "takes a command of up to 100,000 bytes and no more" do
      assert Translate.max_command_bytes() == 100_000

      assert {:ok, %{"command" => _}} =
               Translate.shell_args(%{"command" => String.duplicate("a", 100_000)}, nil)

      assert {:error, message} =
               Translate.shell_args(%{"command" => String.duplicate("é", 50_001)}, nil)

      assert message =~ ~s(shell argument "command" is 100002 bytes; the limit is 100000.)
    end
  end

  describe "view_image_args/2" do
    test "gives the op's args, with the size limit and no directory" do
      assert Translate.view_image_args(%{"machine" => "mm1", "path" => "a.png"}, nil) ==
               {:ok, %{"path" => "a.png", "directory" => nil, "max_size" => 4_999_000}}

      assert Translate.max_size() == 4_999_000
    end

    test "puts the working directory in the op's args, for a relative path to resolve against" do
      assert Translate.view_image_args(%{"path" => "shots/a.png"}, "garden") ==
               {:ok, %{"path" => "shots/a.png", "directory" => "garden", "max_size" => 4_999_000}}
    end

    test "refuses a missing, blank, mistyped or NUL path" do
      for args <- [%{}, %{"path" => nil}, %{"path" => " "}] do
        assert Translate.view_image_args(args, nil) ==
                 {:error, ~s(view_image argument "path" must be set)}
      end

      assert Translate.view_image_args(%{"path" => 3}, nil) ==
               {:error, ~s(view_image argument "path" must be a string)}

      assert Translate.view_image_args(%{"path" => "a\0.png"}, nil) ==
               {:error, ~s(view_image argument "path" contains a NUL byte)}
    end
  end

  describe "result/3 for shell" do
    test "shows stdout, stderr and a nonzero exit code" do
      done = completed(shell_op(), %{"out" => "built", "err" => "warning", "exit_code" => 2})

      assert [%{"type" => "text", "text" => "built\nStderr:\nwarning\nExit code: 2"}] =
               Translate.result("shell", done, "mm1")
    end

    test "leaves out empty streams and exit code 0, or says there was no output" do
      done = completed(shell_op(), %{"out" => "ok\n", "err" => "", "exit_code" => 0})
      assert text(Translate.result("shell", done, "mm1")) == "ok\n"

      done = completed(shell_op(), %{"out" => "", "err" => "", "exit_code" => 0})
      assert text(Translate.result("shell", done, "mm1")) == "(no output)"
    end

    test "shows a failure or a cancel as an error" do
      failed = Operation.fail(shell_op(), "the operation process exited: killed")

      assert text(Translate.result("shell", failed, "mm1")) ==
               "Error: the operation process exited: killed"

      canceled = Operation.advance(shell_op(), "canceled", %{})
      assert text(Translate.result("shell", canceled, "mm1")) == "Error: shell operation canceled"
    end

    test "passes a well-behaved node's truncated output through unchanged" do
      {out, true} = Output.bound(String.duplicate("x", 500), 100, @out_path)
      done = completed(shell_op(100), %{"out" => out, "err" => "", "exit_code" => 0})

      assert text(Translate.result("shell", done, "mm1")) == out
    end

    test "bounds each field again, so a node can't flood the model" do
      flood = String.duplicate("y", 50_000)
      done = completed(shell_op(100), %{"out" => flood, "err" => flood, "exit_code" => 0})
      result = text(Translate.result("shell", done, "mm1"))

      assert String.length(result) < 5_000
      assert result =~ "complete output in #{@out_path}"
      assert result =~ "complete output in #{@err_path}"

      failed = Operation.fail(shell_op(100), flood)
      assert String.length(text(Translate.result("shell", failed, "mm1"))) < 2_500
    end

    test "bounds a field at the default limit when the snapshot's limit is missing" do
      flood = String.duplicate("z", 100_000)
      done = completed(shell_op(nil), %{"out" => flood, "err" => "", "exit_code" => 0})

      assert String.length(text(Translate.result("shell", done, "mm1"))) < 42_000
    end
  end

  describe "result/3 for view_image" do
    test "shows the image and a line with its size, type, path and machine" do
      assert [
               %{"type" => "image", "mime" => "image/png", "data" => "QQ"},
               %{"type" => "text", "text" => "2x3 image/png, /work/a.png on mm1"}
             ] = Translate.result("view_image", image_op(image()), "mm1")
    end

    test "leaves out the size when the image doesn't say" do
      op = image_op(image(%{"width" => nil, "height" => nil, "mime" => "image/webp"}))

      assert [%{"type" => "image"}, %{"text" => "image/webp, /work/a.png on mm1"}] =
               Translate.result("view_image", op, "mm1")
    end

    test "passes on only the four image types, within the size limit" do
      op = image_op(image(%{"mime" => "image/bmp"}))
      assert [%{"type" => "text", "text" => message}] = Translate.result("view_image", op, "mm1")
      assert message =~ "Error: mm1 sent an image the hub can't pass on"

      op = image_op(image(%{"content" => String.duplicate("A", 4_999_001)}))
      assert [%{"type" => "text", "text" => message}] = Translate.result("view_image", op, "mm1")
      assert message =~ "over the limit of 4999000"

      op = image_op(%{"mime" => "image/png"})

      assert [%{"type" => "text", "text" => "Error: " <> _}] =
               Translate.result("view_image", op, "mm1")
    end

    test "shows the job's error, or the snapshot's" do
      op =
        "op_2"
        |> Operation.new("view_image", 1, %{"path" => "/a.bmp"}, nil)
        |> Operation.advance("failed", %{"result" => %{"error" => "unsupported image format"}})

      assert text(Translate.result("view_image", op, "mm1")) == "Error: unsupported image format"

      lost = Operation.fail(Operation.new("op_2", "view_image", 1, %{}, nil), "no record")
      assert text(Translate.result("view_image", lost, "mm1")) == "Error: no record"

      canceled =
        Operation.advance(Operation.new("op_2", "view_image", 1, %{}, nil), "canceled", %{})

      assert text(Translate.result("view_image", canceled, "mm1")) ==
               "Error: view_image operation canceled"
    end
  end

  test "result/3 says so for a snapshot that isn't terminal" do
    assert text(Translate.result("shell", shell_op(), "mm1")) ==
             "Error: the operation on mm1 ended while ready."
  end

  describe "details/3" do
    test "for shell: the command, status, exit code, truncation and full_output" do
      done =
        completed(shell_op(), %{"out" => "a", "err" => "", "exit_code" => 1}, %{
          "out_truncated" => true,
          "err_truncated" => false
        })

      assert Translate.details("shell", done, "mm1") == %{
               "machine" => "mm1",
               "op_id" => "op_1",
               "kind" => "shell",
               "status" => "completed",
               "command" => "make",
               "exit_code" => 1,
               "out_truncated" => true,
               "err_truncated" => false,
               "full_output" =>
                 "Full output: #{@out_path} and #{@err_path} on mm1, kept for 7 days."
             }
    end

    test "for shell: truncated when the hub's own bound cut a field" do
      flood = String.duplicate("y", 5_000)
      done = completed(shell_op(100), %{"out" => "", "err" => flood, "exit_code" => 0})

      assert %{"out_truncated" => false, "err_truncated" => true} =
               Translate.details("shell", done, "mm1")
    end

    test "for shell: no full_output before the command had output files" do
      op =
        shell_op()
        |> put_in(["state", "out_path"], "")
        |> put_in(["state", "err_path"], "")
        |> Operation.fail("no record")

      details = Translate.details("shell", op, "mm1")
      refute Map.has_key?(details, "full_output")
      assert %{"status" => "failed", "exit_code" => nil, "command" => "make"} = details
    end

    test "for view_image: the path and status, and no image data" do
      assert Translate.details("view_image", image_op(image()), "mm1") == %{
               "machine" => "mm1",
               "op_id" => "op_2",
               "kind" => "view_image",
               "status" => "completed",
               "path" => "/work/a.png"
             }
    end
  end

  describe "machine errors" do
    test "an unknown machine lists the ones the hub knows" do
      assert Translate.unknown_machine("mm9", ["local", "mm1"]) ==
               ~s(There is no machine called "mm9". The machines this hub knows are local, mm1.)

      assert Translate.unknown_machine("mm9", []) =~ "doesn't know any machines yet"
    end

    test "an outdated machine says to reinstall" do
      assert Translate.outdated_machine("mm1") ==
               "mm1 runs an older photon-node that can't take commands. " <>
                 "Reinstall it from the Nodes page."
    end
  end
end
