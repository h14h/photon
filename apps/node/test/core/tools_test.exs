defmodule PhotonNode.Harness.ToolsTest do
  @moduledoc """
  The tool registry and the translators: validating calls into a status and
  operations, and formatting recorded results for the model.
  """

  use PhotonNode.Case, async: true

  alias PhotonNode.Harness.Tools.{Bash, SkillUse, ViewImage}

  defp error(status), do: status["error"]

  describe "the registry" do
    test "offers SkillUse only when there are skills, minus disallowed tools" do
      assert Tools.enabled(nil, []) == ["Bash", "ViewImage"]
      assert Tools.enabled(nil, [skill()]) == ["Bash", "ViewImage", "SkillUse"]
      assert Tools.enabled(["Bash"], [skill()]) == ["ViewImage", "SkillUse"]
    end

    test "resolves only enabled tools" do
      assert Tools.resolve("Bash", ["Bash"]) == Bash
      assert Tools.resolve("Bash", ["ViewImage"]) == nil
      assert Tools.resolve("Nope", ["Bash"]) == nil

      assert Enum.map(Tools.definitions(["ViewImage", "Bash"]), & &1["name"]) == [
               "Bash",
               "ViewImage"
             ]
    end
  end

  describe "Bash" do
    test "makes one ready shell operation in the workspace" do
      {status, [op]} = Bash.translate(bash_call("c1", "ls -la"), env())

      assert status == %{"error" => "", "waiting_for" => [op["id"]]}
      assert %{"type" => "shell", "status" => "ready", "max_output_length" => 40_000} = op
      assert "op_" <> _ = op["id"]

      assert op["state"]["input"] == %{
               "command" => "ls -la",
               "shell" => "/bin/sh",
               "directory" => "/work"
             }

      assert op["state"]["base_directory"] == "/work/.photon/operations/s1"
    end

    test "refuses calls it can't run, with the reason as the result" do
      assert {status, []} = Bash.translate(call("c1", "Bash", %{}), env())
      assert error(status) == ~s(bash argument "command" must be set)

      assert {status, []} = Bash.translate(call("c1", "Bash", %{"command" => 3}), env())
      assert error(status) == ~s(decode Bash argument "command": expected a string)

      assert {status, []} = Bash.translate(bash_call("c1", "a\0b"), env())
      assert error(status) == ~s(bash argument "command" contains a NUL byte at offset 1)

      too_long = %{"command" => "ls", "max_output_length" => 2_000_000}
      assert {status, []} = Bash.translate(call("c1", "Bash", too_long), env())
      assert error(status) == "bash argument: max_output_length must not exceed 1000000"

      assert {status, []} = Bash.translate(%{"id" => "c1", "arguments" => "[1]"}, env())
      assert error(status) == "decode Bash arguments: expected a JSON object"

      assert {status, []} = Bash.translate(%{"id" => "c1", "arguments" => "{"}, env())
      assert error(status) =~ "decode Bash arguments: "
    end

    test "formats a finished command's output, errors and exit code" do
      {_status, [op]} = Bash.translate(bash_call("c1", "make"), env())
      result = %{"out" => "built", "err" => "warning", "exit_code" => 2}

      assert [%{"text" => "Command is still running."}] = Bash.format(%{}, [op])

      assert [%{"text" => "built\nStderr:\nwarning\nExit code: 2"}] =
               Bash.format(%{}, [completed(op, result)])

      assert [%{"text" => "Error: the operation process exited: killed"}] =
               Bash.format(%{}, [Operation.fail(op, "the operation process exited: killed")])

      assert [%{"text" => "Error: no"}] = Bash.format(%{"error" => "no"}, [])
    end
  end

  describe "ViewImage" do
    test "reads a path relative to the workspace" do
      {_status, [op]} = ViewImage.translate(call("c1", "ViewImage", %{"path" => "a.png"}), env())
      assert op["state"]["path"] == "/work/a.png"

      {_status, [op]} = ViewImage.translate(call("c1", "ViewImage", %{"path" => "/a.png"}), env())
      assert op["state"]["path"] == "/a.png"
    end

    test "needs a path" do
      assert {status, []} = ViewImage.translate(call("c1", "ViewImage", %{"path" => " "}), env())
      assert error(status) == ~s(ViewImage argument "path" must be set)
    end

    test "shows the image and its size" do
      {_status, [op]} = ViewImage.translate(call("c1", "ViewImage", %{"path" => "a.png"}), env())

      result = %{
        "content" => "QQ",
        "mime" => "image/png",
        "width" => 2,
        "height" => 3,
        "path" => "/work/a.png"
      }

      done = Operation.advance(op, "completed", %{"result" => result})

      assert [
               %{"type" => "image", "data" => "QQ"},
               %{"text" => "dimensions: 2x3; path: /work/a.png"}
             ] =
               ViewImage.format(%{}, [done])
    end
  end

  describe "SkillUse" do
    test "loads a registered skill" do
      env = env(skills: [skill()])
      {status, [op]} = SkillUse.translate(call("c1", "SkillUse", %{"name" => "deploy"}), env)

      assert status["waiting_for"] == [op["id"]]
      assert op["state"]["path"] == skill().path

      assert {status, []} = SkillUse.translate(call("c1", "SkillUse", %{"name" => "x"}), env)
      assert error(status) == ~s(skill "x" is not registered)
    end
  end
end
