defmodule Photon.SkillsFetchDeadlineTest do
  @moduledoc """
  `Photon.Skills.fetch/1` gives up on a server that never finishes
  answering. The deadline is shortened through the app's config, so this
  module runs on its own (`async: false`), after the async ones that
  share that config.
  """

  use ExUnit.Case, async: false

  alias Photon.Skills

  setup do
    config = Application.get_env(:photon, Skills)
    Photon.TestConfig.put_env(:photon, Skills, Keyword.put(config, :deadline, 100))

    test = self()

    # A server that starts answering and never finishes; the request's
    # task is killed at the deadline, which ends the wait.
    Req.Test.stub(Skills, fn conn ->
      send(test, {:asked, conn.host <> conn.request_path})

      receive do
        :never -> conn
      end
    end)
  end

  test "a link to a SKILL.md elsewhere times out" do
    assert Skills.fetch("https://example.com/SKILL.md") ==
             {:error, "The download didn't finish in 15 seconds."}

    assert_received {:asked, "example.com/SKILL.md"}
  end

  test "a GitHub API call times out" do
    assert {:error, "The download didn't finish in 15 seconds."} =
             Skills.fetch("https://github.com/o/r/tree/main/skills")

    assert_received {:asked, "api.github.com/repos/o/r/git/trees/main:skills"}
  end
end
