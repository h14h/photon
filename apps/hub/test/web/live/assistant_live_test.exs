defmodule PhotonWeb.AssistantLiveTest do
  @moduledoc """
  The assistant page, driven as a user would: sending, the in-flight
  answer, the inbox while the assistant is busy, memory, schedules, a
  fresh start, and Blip's mood.
  """

  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Photon.Fixtures, only: [state_record: 1]

  alias Photon.{Assistant, Durable, NodeSessions}

  @moduletag :durable

  ## Named setups

  defp page(%{conn: conn}) do
    conversation = Assistant.conversation_id()
    Durable.subscribe(conversation)
    {:ok, view, _html} = live(conn, ~p"/")
    %{view: view, conversation: conversation}
  end

  # A run that waits for a signal that never comes, so the assistant is busy.
  defp busy(%{view: view, conversation: c}) do
    Durable.commit(
      &Durable.Tx.create_task(&1, %{
        kind: "generation",
        conversation_id: c,
        phase: "after_tools",
        waiting: %{"signal" => "never"}
      })
    )

    _ = render(view)
    :ok
  end

  describe "a conversation" do
    setup :page

    test "shows a tool call with its result inside the answer that made it", %{
      view: view,
      conversation: c
    } do
      view |> form("#composer", message: %{text: "nodes"}) |> render_submit()
      await_entry(c, &(&1.kind == "assistant" and &1.seq > 3))

      assert has_element?(view, "#entries details", "Checked your machines")
      refute has_element?(view, "#empty-state")
    end

    test "an example from the empty state is sent like a message", %{view: view, conversation: c} do
      render_click(view, "example", %{"text" => "help"})
      await_entry(c, &(&1.kind == "assistant"))
      _ = render(view)
      assert has_element?(view, "#entries [id^=entries-]")
    end

    test "node work a call left running settles when its report comes in", %{
      conn: conn,
      view: view,
      conversation: c
    } do
      call = %{
        "id" => "c1",
        "name" => "run_on_node",
        "arguments" => Jason.encode!(%{"node" => "box", "task" => "check disks"})
      }

      Durable.commit(fn tx ->
        Durable.Tx.append(tx, c, "assistant", %{
          "message" => PhotonCore.Message.assistant("Handing that to box.", [call])
        })

        Durable.Tx.append(tx, c, "tool_result", %{
          "message" => PhotonCore.Message.tool_result("c1", "still running"),
          "name" => "run_on_node",
          "status" => "ok",
          "details" => %{"status" => "running", "session_id" => "ns_1", "node" => "box"}
        })
      end)

      assert has_element?(view, "#action-c1[data-status=running]")

      Durable.commit(
        &Durable.Tx.append(&1, c, "user", %{
          "message" => PhotonCore.Message.user("[Report from box] finished"),
          "source" => %{"kind" => "node_report", "node" => "box", "session_id" => "ns_1"}
        })
      )

      assert has_element?(view, "#action-c1[data-status=done]")

      {:ok, reloaded, _html} = live(conn, ~p"/")
      assert has_element?(reloaded, "#action-c1[data-status=done]")
    end

    test "a blank message sends nothing", %{view: view, conversation: c} do
      view |> form("#composer", message: %{text: "   "}) |> render_submit()
      assert Durable.entries(c) == []
    end

    test "shows the in-flight answer until it is committed", %{view: view, conversation: c} do
      send(view.pid, {:live, c, %{"type" => "start"}})
      send(view.pid, {:live, c, %{"type" => "text", "delta" => "Working on it"}})
      assert has_element?(view, "#live-output", "Working on it")

      send(
        view.pid,
        {:live, c, %{"type" => "retry", "delay_ms" => 2000, "message" => "HTTP 503"}}
      )

      assert has_element?(view, "#live-output", "Trying again in 2.0s")
    end
  end

  describe "while the assistant is busy" do
    setup [:page, :busy]

    test "a message waits in the inbox and can be withdrawn", %{view: view} do
      assert has_element?(view, "#stop")

      view |> form("#composer", message: %{text: "and then this"}) |> render_submit()
      _ = render(view)
      assert [queued] = Assistant.queued(Assistant.conversation_id())
      assert has_element?(view, "#queued-#{queued.id}")

      view |> element("#queued-#{queued.id} button") |> render_click()
      refute has_element?(view, "#queued-#{queued.id}")
    end

    test "the mode toggles between steering and following up", %{view: view} do
      assert has_element?(view, "#mode-toggle", "Send after this answer")
      view |> element("#mode-toggle") |> render_click()
      assert has_element?(view, "#mode-toggle", "Steer current work")
    end

    test "stop ends the run", %{view: view, conversation: c} do
      assert has_element?(view, "#blip-live[data-state=thinking]")

      view |> element("#stop") |> render_click()
      await_change(c, &Enum.any?(&1.tasks, fn t -> t.status == "aborted" end))
      _ = render(view)
      refute has_element?(view, "#stop")
      # Stopping isn't finishing: Blip goes back to rest without a hop.
      refute has_element?(view, "#live-output")
      assert has_element?(view, "#blip-nav[data-state=idle]")
    end
  end

  describe "the rail" do
    setup :page

    test "memory can be edited, or the edit cancelled", %{view: view} do
      render_click(view, "edit_memory")
      assert has_element?(view, "#memory-form")
      render_click(view, "cancel_memory")
      refute has_element?(view, "#memory-form")

      render_click(view, "edit_memory")
      view |> form("#memory-form", memory: "  likes tea  ") |> render_submit()
      assert Assistant.memory() == "likes tea"
      refute has_element?(view, "#memory-form")
    end

    test "memory the assistant changes shows up", %{view: view} do
      Assistant.put_memory("the NAS is mp1")
      assert render(view) =~ "the NAS is mp1"
    end

    test "schedules are listed and can be cancelled", %{view: view, conversation: c} do
      routine =
        Durable.create_task(%{
          kind: "routine",
          conversation_id: c,
          background: true,
          input: %{
            "prompt" => "check disks",
            "first_at" => 4_102_444_800_000,
            "every_ms" => 3_600_000
          }
        })

      _ = render(view)
      assert has_element?(view, "#schedule-#{routine.id}", "check disks")
      assert has_element?(view, "#schedule-#{routine.id}", "Every 1h")

      view |> element("#schedule-#{routine.id} button") |> render_click()
      assert Durable.task(routine.id).abort_requested
    end

    test "a fresh start keeps the history and marks the break", %{view: view, conversation: c} do
      render_click(view, "fresh_start")
      await_entry(c, &(&1.kind == "reset"))
      _ = render(view)

      assert has_element?(view, "#flash-info")
      assert has_element?(view, "#entries [id^=entries-]", "Fresh context")
    end
  end

  describe "without a model" do
    test "asks for a ChatGPT sign-in instead of offering a composer", %{conn: conn} do
      Photon.ChatGPTStub.reset!()
      Application.put_env(:photon, :mock_model, false)
      on_exit(fn -> Application.put_env(:photon, :mock_model, true) end)

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#sign-in-to-talk")
      refute has_element?(view, "#composer")
      assert has_element?(view, "#empty-state", "Sign in with ChatGPT")
    end
  end

  describe "Blip" do
    setup :page

    test "rests on an empty conversation, on the page and in the sidebar", %{view: view} do
      assert has_element?(view, "#blip-hello[data-state=idle]")
      assert has_element?(view, "#blip-nav[data-state=idle]")
      refute has_element?(view, "#live-output")
      assert page_title(view) =~ "Blip"
    end

    test "thinks while an answer is in flight", %{view: view, conversation: c} do
      send(view.pid, {:live, c, %{"type" => "start"}})
      assert has_element?(view, "#blip-live[data-state=thinking]")
      assert has_element?(view, "#blip-nav[data-state=thinking]")
    end

    test "hops when a run finishes, and holds still beside its answer", %{
      view: view,
      conversation: c
    } do
      view |> form("#composer", message: %{text: "help"}) |> render_submit()

      await_change(
        c,
        &Enum.any?(&1.tasks, fn t -> t.kind == "generation" and t.status == "done" end)
      )

      assert has_element?(view, "#blip-live[data-state=done]")
      assert has_element?(view, "#entries svg.blip--still[id^=blip-e_]")
    end

    test "is sorry when something goes wrong", %{view: view, conversation: c} do
      Durable.commit(&Durable.Tx.append(&1, c, "error", %{"message" => "HTTP 401"}))
      assert has_element?(view, "#blip-live[data-state=error]")
      assert has_element?(view, "#nav-blip-mood", "failed")
    end

    test "a finish doesn't cover a failure still being shown", %{view: view, conversation: c} do
      run =
        Durable.commit(
          &Durable.Tx.create_task(&1, %{
            kind: "generation",
            conversation_id: c,
            phase: "after_tools",
            waiting: %{"signal" => "never"}
          })
        )

      assert has_element?(view, "#blip-live[data-state=thinking]")

      Durable.commit(&Durable.Tx.append(&1, c, "error", %{"message" => "HTTP 500"}))
      Durable.commit(&Durable.Tx.finish(&1, run, "done", %{}))

      assert has_element?(view, "#blip-live[data-state=error]")
    end

    test "rides a wave while a machine works for it", %{view: view} do
      {:ok, s, _input} =
        NodeSessions.start("box", "check disks", origin: "assistant", title: "Check disks")

      :ok = NodeSessions.ingest(s.id, "box", 0, state_record("running"))

      assert has_element?(view, "#blip-live[data-state=working]")
      assert has_element?(view, "#live-work-#{s.id}", "Check disks")
      assert has_element?(view, "#blip-nav[data-state=working]")
    end
  end
end
