defmodule Photon.AssistantTest do
  @moduledoc """
  The assistant through its API (`Photon.Assistant`) with its mock model:
  its tools (a connected node is played by the test process, which
  registers under the node's name), and schedules.
  """

  use Photon.DataCase, async: false

  @moduletag :durable

  alias Photon.{Assistant, NodeSessions}

  setup do
    conversation = Assistant.conversation_id()
    Durable.subscribe(conversation)
    {:ok, conversation: conversation}
  end

  # Stands in for a connected node: registers under its name, so commands
  # for it arrive here.
  defp fake_node(name) do
    {:ok, _} =
      Registry.register(Photon.NodeRegistry, name, %{
        "platform" => "test",
        "workspace" => "/w",
        "version" => "0",
        "capabilities" => ["ops:1"]
      })
  end

  describe "tools" do
    test "lists machines", %{conversation: c} do
      fake_node("box")
      {:ok, s} = Assistant.send("machines")
      await_settled(c, s.id)
      assert [result] = texts(c, "tool_result")
      assert result =~ "- box: online, test, workspace /w, photon-node 0"
    end

    test "remembers facts", %{conversation: c} do
      {:ok, s} = Assistant.send("remember the NAS is mp1")
      await_settled(c, s.id)
      assert Assistant.memory() =~ "the NAS is mp1"
      assert Assistant.system_prompt(nil) =~ "the NAS is mp1"
    end

    test "searches the web itself: the model gets OpenAI's web search", %{conversation: c} do
      llm = Assistant.llm(%{id: c})
      assert llm.config.hosted_tools == [%{"type" => "web_search"}]
      assert llm.cache_key == c
    end

    test "schedules fire into the conversation", %{conversation: c} do
      {:ok, s} = Assistant.send("in 0 minutes: machines")
      await_settled(c, s.id)

      entry = await_entry(c, &(&1.data["source"]["kind"] == "routine"), 10_000)
      assert PhotonCore.Message.text_of(entry.data["message"]) == "[Scheduled] machines"
    end

    test "without consent to use the plan while away, a schedule leaves a note instead", %{
      conversation: c
    } do
      Application.put_env(:photon, :mock_model, false)
      on_exit(fn -> Application.put_env(:photon, :mock_model, true) end)

      Durable.create_task(%{
        kind: "routine",
        conversation_id: c,
        background: true,
        phase: "fire",
        input: %{"prompt" => "check disks", "first_at" => 0, "every_ms" => nil},
        waiting: %{"until" => 0}
      })

      note = await_entry(c, &(&1.kind == "error"), 10_000)
      assert note.data["notice"]
      assert note.data["message"] =~ ~s{Skipped "check disks"}
      refute Enum.any?(Durable.entries(c), &(&1.data["source"]["kind"] == "routine"))
    end
  end

  describe "node sessions" do
    test "a node that reconnects gets the inputs it missed", %{conversation: _c} do
      {:ok, session, input} = NodeSessions.start("later", "hello")
      refute_receive {:command, _, _}

      fake_node("later")
      NodeSessions.resend_queued("later")
      assert_receive {:command, "input", %{"session_id" => sid, "input" => %{"id" => iid}}}
      assert {sid, iid} == {session.id, input.id}
    end

    test "records arrive in order; gaps and repeats are caught" do
      {:ok, session, _input} = NodeSessions.start("box", "hi")
      assert :ok = NodeSessions.ingest(session.id, "box", 0, %{"kind" => "session"})
      assert :duplicate = NodeSessions.ingest(session.id, "box", 0, %{"kind" => "session"})
      assert {:gap, 1} = NodeSessions.ingest(session.id, "box", 5, %{"kind" => "turn"})
      assert :ignored = NodeSessions.ingest(session.id, "other", 1, %{"kind" => "turn"})
    end
  end
end
