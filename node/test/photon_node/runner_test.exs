defmodule PhotonNode.RunnerTest do
  use ExUnit.Case

  alias PhotonNode.{EventLog, Runner}

  test "builds the runner request from a run config" do
    config = %{
      "provider" => "openai",
      "model" => "gpt-x",
      "disallowed_tools" => ["ViewImage"],
      "max_attempts" => "2"
    }

    assert Runner.request("id", "hello", config) == %{
             "session_id" => "id",
             "prompt" => "hello",
             "thinking_level" => "high",
             "model" => "gpt-x",
             "disallowed_tools" => ["ViewImage"],
             "max_attempts" => 2
           }

    assert Runner.request("id", "hi", %{"provider" => "mock", "model" => ""})["model"] ==
             "mock-model"
  end

  test "points the mock provider at the server's host and unsets blanks otherwise" do
    config = %{PhotonNode.config() | server: "wss://gui.example:8443/node/websocket"}
    env = Runner.env(config, %{"provider" => "mock"})
    assert {"UNREAL_HARNESS_LLM_BASE_URL", "https://gui.example:8443/mock/v1"} in env

    env = Runner.env(config, %{"provider" => "openrouter", "api_key" => "", "base_url" => ""})
    assert {"UNREAL_HARNESS_LLM_API_KEY", false} in env
    assert {"UNREAL_HARNESS_LLM_PROVIDER", "openrouter"} in env
  end

  test "keeps the node's launch plumbing out of the agent's environment" do
    plain = %{
      "RELEASE_COOKIE" => "secret",
      "ROOTDIR" => "/r",
      "HOME" => "/h",
      "LD_LIBRARY_PATH" => "/opt"
    }

    assert Enum.sort(Runner.scrubbed_env(plain)) == [
             {"RELEASE_COOKIE", false},
             {"ROOTDIR", false}
           ]

    burrito = %{
      "__BURRITO" => "1",
      "LD_LIBRARY_PATH" => "/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:/lib:/usr/lib"
    }

    assert {"LD_LIBRARY_PATH", false} in Runner.scrubbed_env(burrito)

    burrito = %{burrito | "LD_LIBRARY_PATH" => "/opt/cuda:" <> burrito["LD_LIBRARY_PATH"]}
    assert {"LD_LIBRARY_PATH", "/opt/cuda"} in Runner.scrubbed_env(burrito)
  end

  @tag :tmp_dir
  test "writes attachments into the workspace, refusing paths outside .attachments", %{
    tmp_dir: dir
  } do
    image = %{"path" => ".attachments/20260923-0-cat.png", "data" => Base.encode64("PNG!")}
    assert Runner.write_attachments(dir, [image]) == :ok
    assert File.read!(Path.join(dir, ".attachments/20260923-0-cat.png")) == "PNG!"

    for path <- ["../escape.png", ".attachments/../x.png", "/etc/x.png", ".attachments/a/b.png"] do
      assert {:error, _} = Runner.write_attachments(dir, [%{image | "path" => path}])
    end

    assert {:error, _} = Runner.write_attachments(dir, [%{image | "data" => "not base64!"}])
  end

  @tag :tmp_dir
  test "runs a runner, logging stdout JSON, stderr lines and the exit", %{tmp_dir: dir} do
    # A stand-in for unreal-agent-runner: prints its last argument (the JSON
    # request) back as an event, then a stderr line, then fails.
    fake = Path.join(dir, "fake-runner")

    File.write!(fake, """
    #!/bin/sh
    for last; do :; done
    printf '{"Kind":"input","Data":%s}\\n' "$last"
    echo 'something on stderr' >&2
    exit 3
    """)

    File.chmod!(fake, 0o755)

    :persistent_term.put({PhotonNode, :config}, %{
      PhotonNode.config()
      | runner: fake,
        workspace: dir
    })

    id = "run-#{System.unique_integer([:positive])}"

    assert {:ok, pid} = Runner.start(id, "hello", %{"provider" => "mock"})
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, _, _, :normal}, 5_000

    assert [
             {0, %{"Kind" => "input", "Data" => %{"prompt" => "hello", "session_id" => ^id}}},
             {1, %{"type" => "stderr", "message" => "something on stderr"}},
             {2, %{"type" => "exit", "status" => 3}}
           ] = EventLog.read_from(id, 0)

    assert Runner.start(id, "x", %{"workspace" => Path.join(dir, "missing")}) ==
             {:error,
              "Workspace #{Path.join(dir, "missing")} is not a directory on node test-node."}
  end
end
