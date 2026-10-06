defmodule PhotonNode.Ops.JobsTest do
  @moduledoc """
  The one-shot operation: `view_image` reads a file as a plain function,
  and `Ops.Job` runs it off its owner. The test process is the owner
  (`PhotonNode.TestOwner`).
  """

  use PhotonNode.NodeCase, async: false

  alias PhotonCore.Operation
  alias PhotonNode.Ops
  alias PhotonNode.Ops.ViewImage
  alias PhotonNode.TestOwner

  @png <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13, "IHDR", 2::32, 3::32, 8, 6, 0, 0, 0>>

  defp in_workspace(%{workspace: workspace}) do
    File.mkdir_p!(workspace)
    :ok
  end

  defp view_op(path, max_size \\ 4_999_000) do
    state = %{"path" => path, "max_size" => max_size, "result" => nil}
    Operation.new("op_view", "view_image", 1, state, nil)
  end

  describe "view_image" do
    setup :in_workspace

    test "returns the image, its type and size", %{workspace: workspace} do
      path = Path.join(workspace, "a.png")
      File.write!(path, @png)

      assert %{"status" => "completed", "state" => %{"result" => result}} =
               ViewImage.run(view_op(path))

      assert result == %{
               "content" => Base.encode64(@png),
               "mime" => "image/png",
               "width" => 2,
               "height" => 3,
               "path" => path
             }
    end

    test "fails for a missing file, a directory, an unknown format, or an image over the limit",
         %{workspace: workspace} do
      text = Path.join(workspace, "notes.txt")
      File.write!(text, "hello")
      png = Path.join(workspace, "a.png")
      File.write!(png, @png)

      assert error(ViewImage.run(view_op(Path.join(workspace, "nope.png")))) ==
               "read image: no such file or directory"

      assert error(ViewImage.run(view_op(workspace))) =~ "is a directory, not a file"
      assert error(ViewImage.run(view_op(text))) =~ "not a recognised image"
      assert error(ViewImage.run(view_op(png, 4))) =~ "the limit is 4"
    end

    defp error(%{"status" => "failed", "state" => %{"result" => %{"error" => error}}}), do: error
  end

  describe "the job worker" do
    setup :in_workspace

    test "reports the job's snapshot to its owner and stops", %{workspace: workspace} do
      path = Path.join(workspace, "a.png")
      File.write!(path, @png)
      op = view_op(path)

      {:ok, pid} = Ops.add(op, TestOwner.owner())
      ref = Process.monitor(pid)

      assert_receive {:report, %{"id" => id, "status" => "completed"}}
      assert id == op["id"]
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end

    test "an operation of a type nobody runs can't be added" do
      assert {:error, "unsupported operation type \"teleport\""} =
               Ops.add(Operation.new("op_teleport", "teleport", 1, %{}, nil), TestOwner.owner())
    end
  end
end
