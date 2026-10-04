defmodule PhotonWeb.BlipLiveTest do
  @moduledoc """
  Blip, floating over the pages, driven as a user would: the conversation
  (sending, the in-flight answer, the inbox while the assistant is busy),
  the panel, what Blip says while it's closed, the page it offers as
  context, and its mood.
  """

  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Photon.Fixtures, only: [state_record: 1, state_record: 2]

  alias Photon.{Assistant, Durable, NodeSessions}

  @moduletag :durable

  ## Named setups

  # The overview page with Blip over it; `blip` is Blip's own LiveView.
  defp page(%{conn: conn}) do
    conversation = Assistant.conversation_id()
    Durable.subscribe(conversation)
    {:ok, view, _html} = live(conn, ~p"/")
    %{view: view, blip: find_live_child(view, "blip"), conversation: conversation}
  end

  defp opened(%{blip: blip}) do
    render_hook(blip, "panel", %{"to" => "open"})
    :ok
  end

  # A run that waits for a signal that never comes, so the assistant is busy.
  defp busy(%{blip: blip, conversation: c}) do
    Durable.commit(
      &Durable.Tx.create_task(&1, %{
        kind: "generation",
        conversation_id: c,
        phase: "after_tools",
        waiting: %{"signal" => "never"}
      })
    )

    _ = render(blip)
    :ok
  end

  describe "one Blip" do
    setup :page

    test "floats over every page, and is the only Blip there", %{conn: conn, view: view} do
      assert has_element?(view, "#blip #blip-face svg#blip-avatar")
      assert blips(view) == 1
      refute has_element?(view, "#sidebar a[href='/']", "Blip")

      for path <- [~p"/nodes", ~p"/settings"] do
        {:ok, other, _html} = live(conn, path)
        assert has_element?(other, "#blip #blip-face")
        assert blips(other) == 1
      end
    end
  end

  describe "the panel" do
    setup :page

    test "starts closed, and opens, pins, fills the window and closes", %{blip: blip} do
      assert has_element?(blip, "#blip-dock[data-panel=closed]")
      assert has_element?(blip, "#blip-face[aria-expanded=false]")

      for to <- ~w(open pinned full closed) do
        render_hook(blip, "panel", %{"to" => to})
        assert has_element?(blip, "#blip-dock[data-panel=#{to}]")
      end
    end
  end

  describe "a conversation" do
    setup [:page, :opened]

    test "shows a tool call with its result inside the answer that made it", %{
      blip: blip,
      conversation: c
    } do
      assert has_element?(blip, "#empty-state")
      blip |> form("#composer", message: %{text: "nodes"}) |> render_submit()
      await_entry(c, &(&1.kind == "assistant" and &1.seq > 3))

      assert has_element?(blip, "#entries details", "Checked your machines")
      refute has_element?(blip, "#empty-state")
    end

    test "an example from the empty state is sent like a message", %{blip: blip, conversation: c} do
      render_click(blip, "example", %{"text" => "help"})
      await_entry(c, &(&1.kind == "assistant"))
      _ = render(blip)
      assert has_element?(blip, "#entries [id^=entries-]")
    end

    test "node work a call left running settles when its report comes in", %{
      conn: conn,
      blip: blip,
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

      assert has_element?(blip, "#action-c1[data-status=running]")

      Durable.commit(
        &Durable.Tx.append(&1, c, "user", %{
          "message" => PhotonCore.Message.user("[Report from box] finished"),
          "source" => %{"kind" => "node_report", "node" => "box", "session_id" => "ns_1"}
        })
      )

      assert has_element?(blip, "#action-c1[data-status=done]")

      {:ok, reloaded, _html} = live(conn, ~p"/")
      assert has_element?(find_live_child(reloaded, "blip"), "#action-c1[data-status=done]")
    end

    test "a blank message sends nothing", %{blip: blip, conversation: c} do
      blip |> form("#composer", message: %{text: "   "}) |> render_submit()
      assert Durable.entries(c) == []
    end

    test "shows the in-flight answer until it is committed", %{blip: blip, conversation: c} do
      send(blip.pid, {:live, c, %{"type" => "start"}})
      send(blip.pid, {:live, c, %{"type" => "text", "delta" => "Working on it"}})
      assert has_element?(blip, "#live-output", "Working on it")

      send(
        blip.pid,
        {:live, c, %{"type" => "retry", "delay_ms" => 2000, "message" => "HTTP 503"}}
      )

      assert has_element?(blip, "#live-output", "Trying again in 2.0s")
    end
  end

  describe "while the assistant is busy" do
    setup [:page, :opened, :busy]

    test "a message waits in the inbox and can be withdrawn", %{blip: blip} do
      assert has_element?(blip, "#stop")

      blip |> form("#composer", message: %{text: "and then this"}) |> render_submit()
      _ = render(blip)
      assert [queued] = Assistant.queued(Assistant.conversation_id())
      assert has_element?(blip, "#queued-#{queued.id}", "and then this")

      blip |> element("#queued-#{queued.id} button") |> render_click()
      refute has_element?(blip, "#queued-#{queued.id}")
    end

    test "the mode toggles between steering and following up", %{blip: blip} do
      assert has_element?(blip, "#mode-toggle", "Send after this answer")
      blip |> element("#mode-toggle") |> render_click()
      assert has_element?(blip, "#mode-toggle", "Steer current work")
    end

    test "stop ends the run", %{blip: blip, conversation: c} do
      assert has_element?(blip, "#blip-avatar[data-state=thinking]")

      blip |> element("#stop") |> render_click()
      await_change(c, &Enum.any?(&1.tasks, fn t -> t.status == "aborted" end))
      _ = render(blip)
      refute has_element?(blip, "#stop")
      # Stopping isn't finishing: Blip goes back to rest without a hop.
      refute has_element?(blip, "#live-output")
      assert has_element?(blip, "#blip-avatar[data-state=idle]")
    end
  end

  describe "while the panel is closed" do
    setup :page

    test "Blip says its answer in the pill and counts it unread", %{blip: blip, conversation: c} do
      refute has_element?(blip, "#blip-pill")
      Assistant.send("help")
      await_entry(c, &(&1.kind == "assistant"))

      assert has_element?(blip, "#blip-pill", "I'm Blip, on the scripted model")
      assert has_element?(blip, "#blip-unread", "1")
      assert has_element?(blip, "#blip-dock[data-notice]")
    end

    test "opening the panel reads what was unread", %{blip: blip, conversation: c} do
      Durable.commit(&Durable.Tx.append(&1, c, "error", %{"message" => "HTTP 401"}))
      assert has_element?(blip, "#blip-pill.is-failed", "HTTP 401")

      render_hook(blip, "panel", %{"to" => "open"})
      refute has_element?(blip, "#blip-pill")
      refute has_element?(blip, "#blip-unread")
    end

    test "a stopped run says nothing", %{blip: blip, conversation: c} do
      Durable.commit(
        &Durable.Tx.append(&1, c, "error", %{"message" => "Stopped.", "stopped" => true})
      )

      refute has_element?(blip, "#blip-pill")
    end

    test "work you started yourself is mentioned only when it fails", %{blip: blip} do
      {:ok, fine, _input} = NodeSessions.start("box", "uptime", title: "Uptime")
      {:ok, broken, _input} = NodeSessions.start("box", "backup", title: "Backup")

      for s <- [fine, broken],
          do: :ok = NodeSessions.ingest(s.id, "box", 0, state_record("running"))

      _ = render(blip)

      :ok =
        NodeSessions.ingest(fine.id, "box", 1, state_record("idle", %{"answer" => "up 3 days"}))

      refute has_element?(blip, "#blip-pill")

      :ok =
        NodeSessions.ingest(
          broken.id,
          "box",
          1,
          state_record("idle", %{"failure" => "disk full"})
        )

      assert has_element?(blip, ~s(#blip-pill[href="/sessions/#{broken.id}"]), "couldn't finish")

      # Opened, the failure stays at the top of the panel until dismissed.
      render_hook(blip, "panel", %{"to" => "open"})
      assert has_element?(blip, "#blip-notice-bar", "Backup")
      blip |> element("#blip-notice-bar button") |> render_click()
      refute has_element?(blip, "#blip-notice-bar")
    end
  end

  describe "the page under Blip" do
    setup [:page, :opened]

    test "a node session's page goes with the next message", %{blip: blip, conversation: c} do
      {:ok, session, _input} = NodeSessions.start("box", "backup", title: "Nightly backup")

      render_hook(blip, "page", %{"path" => "/sessions/#{session.id}"})
      assert has_element?(blip, "#page-chip", "box / Nightly backup")

      blip |> form("#composer", message: %{text: "nodes"}) |> render_submit()
      entry = await_entry(c, &(&1.kind == "user"))

      assert entry.data["source"]["page"]["session_id"] == session.id
      assert PhotonCore.Message.text_of(entry.data["message"]) =~ ~s([Looking at box's session)

      # Shown as typed, with what it was about; the scripted model still
      # understood it.
      await_entry(c, &(&1.kind == "assistant" and &1.seq > 3))
      _ = render(blip)
      assert has_element?(blip, "#entries", "About box / Nightly backup")
      refute has_element?(blip, "#entries", "Looking at")
      assert has_element?(blip, "#entries details", "Checked your machines")
    end

    test "can be left out, until the page changes", %{blip: blip, conversation: c} do
      {:ok, session, _input} = NodeSessions.start("box", "backup", title: "Nightly backup")
      render_hook(blip, "page", %{"path" => "/sessions/#{session.id}"})

      blip |> element("#page-chip-dismiss") |> render_click()
      refute has_element?(blip, "#page-chip")

      blip |> form("#composer", message: %{text: "help"}) |> render_submit()
      entry = await_entry(c, &(&1.kind == "user"))
      assert entry.data["source"] == %{"kind" => "user"}

      render_hook(blip, "page", %{"path" => "/sessions/#{session.id}"})
      assert has_element?(blip, "#page-chip")
    end

    test "other pages offer nothing", %{blip: blip} do
      for path <- ["/", "/nodes", "/sessions/missing", "/sessions/a/b"] do
        render_hook(blip, "page", %{"path" => path})
        refute has_element?(blip, "#page-chip")
      end
    end
  end

  describe "without a model" do
    test "asks for a ChatGPT sign-in instead of offering a composer", %{conn: conn} do
      Photon.ChatGPTStub.reset!()
      Application.put_env(:photon, :mock_model, false)
      on_exit(fn -> Application.put_env(:photon, :mock_model, true) end)

      {:ok, view, _html} = live(conn, ~p"/")
      blip = find_live_child(view, "blip")
      assert has_element?(blip, "#sign-in-to-talk")
      refute has_element?(blip, "#composer")
      assert has_element?(blip, "#empty-state", "Sign in with ChatGPT")
      assert has_element?(blip, "#blip-status", "Needs a ChatGPT sign-in")
    end
  end

  describe "Blip's mood" do
    setup :page

    test "rests on an empty conversation", %{blip: blip} do
      assert has_element?(blip, "#blip-avatar[data-state=idle]")
      refute has_element?(blip, "#live-output")
    end

    test "thinks while an answer is in flight", %{blip: blip, conversation: c} do
      send(blip.pid, {:live, c, %{"type" => "start"}})
      assert has_element?(blip, "#blip-avatar[data-state=thinking]")
      assert has_element?(blip, "#blip-status", "Thinking")
    end

    test "hops when a run finishes", %{blip: blip} do
      blip |> form("#composer", message: %{text: "help"}) |> render_submit()

      await_change(
        Assistant.conversation_id(),
        &Enum.any?(&1.tasks, fn t -> t.kind == "generation" and t.status == "done" end)
      )

      assert has_element?(blip, "#blip-avatar[data-state=done]")
    end

    test "is sorry when something goes wrong", %{blip: blip, conversation: c} do
      Durable.commit(&Durable.Tx.append(&1, c, "error", %{"message" => "HTTP 401"}))
      assert has_element?(blip, "#blip-avatar[data-state=error]")
      assert has_element?(blip, "#blip-status", "Something failed")
    end

    test "a finish doesn't cover a failure still being shown", %{blip: blip, conversation: c} do
      run =
        Durable.commit(
          &Durable.Tx.create_task(&1, %{
            kind: "generation",
            conversation_id: c,
            phase: "after_tools",
            waiting: %{"signal" => "never"}
          })
        )

      assert has_element?(blip, "#blip-avatar[data-state=thinking]")

      Durable.commit(&Durable.Tx.append(&1, c, "error", %{"message" => "HTTP 500"}))
      Durable.commit(&Durable.Tx.finish(&1, run, "done", %{}))

      assert has_element?(blip, "#blip-avatar[data-state=error]")
    end

    test "rides a wave while a machine works for it", %{blip: blip} do
      render_hook(blip, "panel", %{"to" => "open"})

      {:ok, s, _input} =
        NodeSessions.start("box", "check disks", origin: "assistant", title: "Check disks")

      :ok = NodeSessions.ingest(s.id, "box", 0, state_record("running"))

      assert has_element?(blip, "#blip-avatar[data-state=working]")
      assert has_element?(blip, "#live-work-#{s.id}", "Check disks")
      assert has_element?(blip, "#blip-status", "box is working on it")
    end
  end

  # How many Blips the whole page draws.
  defp blips(view) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("svg.blip") |> Enum.count()
  end
end
