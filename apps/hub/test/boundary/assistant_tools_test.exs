defmodule Photon.AssistantToolsTest do
  @moduledoc """
  The assistant's tools through their `Photon.Durable.Tool` API
  (`execute/2`), the way a tool task calls them, against the database. A
  connected node is played by the test process, registered under the
  node's name.
  """

  use Photon.DataCase, async: false

  import Photon.Fixtures,
    only: [call: 2, input_record: 1, record: 2, state_record: 2, tool_task: 2]

  alias Photon.Assistant.Tools
  alias Photon.Durable.ToolAPI
  alias Photon.NodeSessions
  alias PhotonCore.Message

  @moduletag :durable

  ## Named setups

  defp conversation(_context), do: %{conversation: Photon.Assistant.conversation_id()}

  defp connected_node(_context) do
    {:ok, _} =
      Registry.register(Photon.NodeRegistry, "box", %{
        "platform" => "linux",
        "workspace" => "/w",
        "version" => "1"
      })

    :ok
  end

  defp node_session(_context) do
    {:ok, session, input} = NodeSessions.start("box", "check disks")
    %{session: session, input: input}
  end

  defp api(%{conversation: c}, name, task_id \\ "t_tool") do
    ToolAPI.new(tool_task(call(name, %{}), id: task_id, conversation_id: c))
  end

  defp text({:ok, content, _details}), do: Message.text_of(content)

  describe "list_nodes" do
    setup :conversation

    test "says when there are no nodes yet", ctx do
      assert {:ok, "No nodes yet." <> _} = Tools.ListNodes.execute(%{}, api(ctx, "list_nodes"))
    end

    test "lists online nodes with their recent sessions, then offline ones", ctx do
      connected_node(ctx)
      {:ok, _, _} = NodeSessions.start("box", "check disks")
      {:ok, _, _} = NodeSessions.start("nas", "back up")

      {:ok, text} = Tools.ListNodes.execute(%{}, api(ctx, "list_nodes"))

      assert text =~ "- box: online (linux, workspace /w, photon-node 1)"
      assert text =~ ~s("check disks" (pending)
      assert text =~ "- nas: offline"
    end
  end

  describe "check_node_session" do
    setup [:conversation, :node_session]

    test "refuses a session it doesn't know", ctx do
      assert Tools.CheckNodeSession.execute(%{"session_id" => "ns_nope"}, api(ctx, "check")) ==
               {:error, "There is no node session ns_nope."}
    end

    test "shows the status, latest answer and recent commands", %{session: s, input: i} = ctx do
      op = %{
        "type" => "shell",
        "status" => "completed",
        "state" => %{"input" => %{"command" => "df -h"}, "result" => %{"out" => "plenty"}}
      }

      records = [
        record("session", %{}),
        input_record(i.id),
        record("tool_call_status", %{"call_id" => "c1", "operations" => [op]}),
        state_record("idle", %{"answer" => "disks are fine"})
      ]

      for {r, offset} <- Enum.with_index(records),
          do: :ok = NodeSessions.ingest(s.id, "box", offset, r)

      result = Tools.CheckNodeSession.execute(%{"session_id" => s.id}, api(ctx, "check"))

      assert {:ok, _, %{"session_id" => id, "node" => "box"}} = result
      assert id == s.id
      assert text(result) =~ "(idle, updated"
      assert text(result) =~ "Latest answer:\ndisks are fine"
      assert text(result) =~ "Recent commands:\n$ df -h\nplenty"
    end
  end

  describe "message_node_session" do
    setup [:conversation, :node_session]

    test "needs a known session on an online node", %{session: s} = ctx do
      assert {:error, "There is no node session ns_nope."} =
               Tools.MessageNodeSession.execute(
                 %{"session_id" => "ns_nope", "message" => "hi"},
                 api(ctx, "msg")
               )

      assert Tools.MessageNodeSession.execute(
               %{"session_id" => s.id, "message" => "hi"},
               api(ctx, "msg")
             ) ==
               {:error, "box is offline."}
    end

    test "sends the message and waits for the answer, with a watcher", %{session: s} = ctx do
      connected_node(ctx)

      assert {:wait, %{"signal" => "node_input:in_tool", "until" => _}, state} =
               Tools.MessageNodeSession.execute(
                 %{"session_id" => s.id, "message" => "and the NAS?", "wait_seconds" => 0},
                 api(ctx, "msg", "t_tool")
               )

      assert %{"session_id" => sid, "input_id" => "in_tool", "watcher" => watcher} = state
      assert sid == s.id
      assert_receive {:command, "input", %{"input" => %{"id" => "in_tool"}}}
      assert %{kind: "node_watch", request_id: "watch:in_tool"} = Durable.task(watcher)
    end
  end

  describe "stop_node_session" do
    setup [:conversation, :node_session]

    test "queues a stop the node gets now, or when it reconnects", %{session: s} = ctx do
      assert {:ok, "box is offline. It will stop session " <> _, %{"node" => "box"}} =
               Tools.StopNodeSession.execute(%{"session_id" => s.id}, api(ctx, "stop"))

      assert NodeSessions.input("stop_tool").state == "queued"

      connected_node(ctx)

      # A rerun of the same call (after a restart) is the same stop.
      assert {:ok, "Asked box to stop session " <> _, %{"node" => "box"}} =
               Tools.StopNodeSession.execute(%{"session_id" => s.id}, api(ctx, "stop"))

      assert_receive {:command, "input", %{"session_id" => id, "input" => %{"id" => "stop_tool"}}}
      assert id == s.id
    end

    test "refuses a session it doesn't know", ctx do
      assert {:error, "There is no node session ns_nope."} =
               Tools.StopNodeSession.execute(%{"session_id" => "ns_nope"}, api(ctx, "stop"))
    end
  end

  describe "schedules" do
    setup :conversation

    test "start in some minutes, or at a time, optionally repeating", ctx do
      assert {:ok, "Scheduled " <> _, %{"schedule_id" => id}} =
               Tools.Schedule.execute(
                 %{"prompt" => "check disks", "in_minutes" => 10},
                 api(ctx, "schedule", "t_s1")
               )

      assert %{
               kind: "routine",
               background: true,
               input: %{"prompt" => "check disks", "every_ms" => nil}
             } =
               Durable.task(id)

      assert {:ok, text, _} =
               Tools.Schedule.execute(
                 %{"prompt" => "ping", "at" => "2099-01-01T09:00:00Z", "every_minutes" => 60},
                 api(ctx, "schedule", "t_s2")
               )

      assert text =~ "first at 2099-01-01 09:00 UTC, then every 60 minutes"

      assert {:ok, _, _} =
               Tools.Schedule.execute(
                 %{"prompt" => "p", "every_minutes" => 5},
                 api(ctx, "schedule", "t_s3")
               )
    end

    test "refuse a time in the past, a bad time, too short an interval, or no time", ctx do
      api = api(ctx, "schedule")

      assert {:error, "2000-01-01T00:00:00Z is in the past."} =
               Tools.Schedule.execute(%{"prompt" => "p", "at" => "2000-01-01T00:00:00Z"}, api)

      assert {:error, "at must be ISO 8601" <> _} =
               Tools.Schedule.execute(%{"prompt" => "p", "at" => "tomorrow"}, api)

      assert {:error, "every_minutes must be at least 5."} =
               Tools.Schedule.execute(
                 %{"prompt" => "p", "in_minutes" => 1, "every_minutes" => 1},
                 api
               )

      assert {:error, "Give in_minutes or at."} = Tools.Schedule.execute(%{"prompt" => "p"}, api)
    end

    test "are listed with their next time, and cancelled by ID", ctx do
      assert {:ok, "No schedules. (Now: " <> _} =
               Tools.ListSchedules.execute(%{}, api(ctx, "list"))

      {:ok, _, %{"schedule_id" => id}} =
        Tools.Schedule.execute(
          %{"prompt" => "ping", "in_minutes" => 5, "every_minutes" => 30},
          api(ctx, "schedule", "t_s4")
        )

      {:ok, listed} = Tools.ListSchedules.execute(%{}, api(ctx, "list"))
      assert listed =~ ~s(- #{id}: next )
      assert listed =~ ~s(, every 30 min: "ping")

      assert Tools.CancelSchedule.execute(%{"schedule_id" => id}, api(ctx, "cancel")) ==
               {:ok, "Cancelled #{id}."}

      assert Durable.task(id).abort_requested

      assert Tools.CancelSchedule.execute(%{"schedule_id" => "t_nope"}, api(ctx, "cancel")) ==
               {:error, "There is no schedule t_nope."}
    end
  end
end
