defmodule PhotonNode.Harness.JobsTest do
  @moduledoc """
  The one-shot operations: `view_image` and `skill_use` read files as plain
  functions, and `Ops.Job` runs them off the coordinator. The test process
  stands in for the session's coordinator (registered under its ID).
  """

  use PhotonNode.HarnessCase, async: false

  alias PhotonCore.Operation
  alias PhotonNode.Harness.Ops
  alias PhotonNode.Harness.Ops.{SkillUse, ViewImage}

  @png <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13, "IHDR", 2::32, 3::32, 8, 6, 0, 0, 0>>

  defp in_workspace(%{workspace: workspace}) do
    File.mkdir_p!(workspace)
    :ok
  end

  defp view_op(path, max_size \\ 4_999_000),
    do: Operation.new("view_image", 1, %{"path" => path, "max_size" => max_size, "result" => nil})

  defp skill_op(path),
    do: Operation.new("skill_use", 1, %{"path" => path, "content" => nil, "terminal_error" => ""})

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

  describe "skill_use" do
    setup :in_workspace

    test "returns the skill's instructions", %{workspace: workspace} do
      path = Path.join(workspace, "SKILL.md")
      File.write!(path, "---\nname: deploy\n---\nRun make.")

      assert %{
               "status" => "completed",
               "state" => %{"content" => "---\nname: deploy\n---\nRun make."}
             } =
               SkillUse.run(skill_op(path))
    end

    test "fails when the file is gone", %{workspace: workspace} do
      assert %{"status" => "failed", "state" => %{"terminal_error" => error}} =
               SkillUse.run(skill_op(Path.join(workspace, "SKILL.md")))

      assert error == "read skill: no such file or directory"
    end
  end

  describe "the job worker" do
    setup :in_workspace

    test "reports the job's snapshot to the session's coordinator and stops", %{
      workspace: workspace
    } do
      {:ok, _} = Registry.register(PhotonNode.SessionRegistry, "jobs1", nil)
      path = Path.join(workspace, "a.png")
      File.write!(path, @png)
      op = view_op(path)

      {:ok, pid} = Ops.add(op, "jobs1")
      ref = Process.monitor(pid)

      assert_receive {:op_update, %{"id" => id, "status" => "completed"}}
      assert id == op["id"]
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end

    test "an operation of a type nobody runs can't be added" do
      assert {:error, "unsupported operation type \"teleport\""} =
               Ops.add(Operation.new("teleport", 1, %{}), "jobs2")
    end
  end
end
