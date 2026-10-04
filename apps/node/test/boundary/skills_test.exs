defmodule PhotonNode.Harness.SkillsTest do
  @moduledoc "Skill discovery reads the workspace; the prompt section is pure."

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import PhotonNode.Fixtures, only: [skill: 1]

  alias PhotonNode.Harness.Skills

  @moduletag :tmp_dir

  defp write_skill(workspace, folder, body) do
    path = Path.join([workspace, ".harness", "skills", folder, "SKILL.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    path
  end

  test "finds skills by their front matter, the first one for each name", %{tmp_dir: workspace} do
    deploy =
      write_skill(workspace, "a", "---\nname: deploy\ndescription: How to deploy\n---\nRun make.")

    write_skill(workspace, "b", "---\nname: deploy\ndescription: Another way\n---\n")
    write_skill(workspace, "c", "no front matter")
    write_skill(workspace, "d", "---\nname: half\n---\n")

    log =
      capture_log(fn ->
        assert [%{name: "deploy", description: "How to deploy", path: ^deploy}] =
                 Skills.discover(workspace)
      end)

    assert log =~ "missing front matter"
    assert log =~ "front matter needs a name and a description"
  end

  test "a workspace without skills has none", %{tmp_dir: workspace} do
    assert Skills.discover(workspace) == []
    assert Skills.prompt([]) == nil
  end

  test "the prompt lists skills with their text escaped" do
    prompt = Skills.prompt([skill(name: "a<b", description: ~s(say "hi" & 'bye'))])

    assert prompt =~
             "<skill><name>a&lt;b</name><description>say &#34;hi&#34; &amp; &#39;bye&#39;</description>"
  end
end
