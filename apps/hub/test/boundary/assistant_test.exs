defmodule Photon.AssistantTest do
  @moduledoc """
  The assistant through its API (`Photon.Assistant`) with its mock model:
  its tools, handing work to a node (played by the test process, which
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
        "version" => "0"
      })
  end

  defp node_records(session_id, input_id, answer) do
    [
      %{"kind" => "session", "data" => %{"id" => session_id}},
      %{
        "kind" => "input",
        "data" => %{"id" => input_id, "kind" => "external", "payload" => %{"content" => "x"}}
      },
      %{"kind" => "state", "data" => %{"state" => "running"}},
      %{"kind" => "state", "data" => %{"state" => "idle", "answer" => answer}}
    ]
  end

  defp play(session_id, node, records, from \\ 0) do
    records
    |> Enum.with_index(from)
    |> Enum.each(fn {r, offset} ->
      assert :ok = NodeSessions.ingest(session_id, node, offset, r)
    end)
  end

  describe "tools" do
    test "lists nodes", %{conversation: c} do
      fake_node("box")
      {:ok, s} = Assistant.send("nodes")
      await_settled(c, s.id)
      assert [result] = texts(c, "tool_result")
      assert result =~ "box: online"
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
      {:ok, s} = Assistant.send("in 0 minutes: nodes")
      await_settled(c, s.id)

      entry = await_entry(c, &(&1.data["source"]["kind"] == "routine"), 10_000)
      assert PhotonCore.Message.text_of(entry.data["message"]) == "[Scheduled] nodes"
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

  describe "node work" do
    test "work on an offline node is refused", %{conversation: c} do
      {:ok, s} = Assistant.send("on ghost: $ uptime")
      await_settled(c, s.id)
      assert [result] = texts(c, "tool_result")
      assert result =~ "offline or unknown"
    end

    test "hands work to a node and returns a quick answer", %{conversation: c} do
      fake_node("box")
      {:ok, s} = Assistant.send("on box: $ uptime")

      assert_receive {:command, "input",
                      %{"session_id" => session_id, "input" => %{"id" => input_id}}},
                     5_000

      play(session_id, "box", node_records(session_id, input_id, "up 3 days"))

      await_settled(c, s.id)
      assert [result] = texts(c, "tool_result")
      assert result =~ "up 3 days"
      assert NodeSessions.get(session_id).status == "idle"

      # The early answer means no report follows.
      refute Enum.any?(Durable.entries(c), &(&1.data["source"]["kind"] == "node_report"))
    end

    test "work that outlasts the wait is reported later", %{conversation: c} do
      fake_node("box")
      {:ok, s} = Assistant.send("on box: sleep 60")

      assert_receive {:command, "input",
                      %{"session_id" => session_id, "input" => %{"id" => input_id}}},
                     5_000

      # The tool waits five seconds for the mock; let it time out.
      await_settled(c, s.id, 10_000)
      assert [result] = texts(c, "tool_result")
      assert result =~ "still running"

      play(session_id, "box", node_records(session_id, input_id, "slept well"))

      report = await_entry(c, &(&1.data["source"]["kind"] == "node_report"))
      assert PhotonCore.Message.text_of(report.data["message"]) =~ "slept well"

      # The report wakes the assistant, which relays it.
      await_entry(c, &(&1.kind == "assistant" and &1.seq > report.seq))
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
