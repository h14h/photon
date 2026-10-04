defmodule PhotonWeb.SessionLiveTest do
  @moduledoc "One node session's page: messages, stop, live output, delete."

  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Photon.Fixtures, only: [call: 3, record: 2]

  alias Photon.{Nodes, NodeSessions}

  @moduletag :durable

  ## Named setups

  defp session_page(%{conn: conn}) do
    {:ok, session, _input} = NodeSessions.start("box", "check disks")
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    %{view: view, session: session}
  end

  defp node_online(_context) do
    {:ok, _} = Registry.register(Photon.NodeRegistry, "box", %{"version" => "1"})
    Nodes.broadcast()
    :ok
  end

  test "an unknown session sends you back to the assistant", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/sessions/ns_nope")
  end

  describe "a session on an offline node" do
    setup :session_page

    test "says it waits for the node, and can't send", %{view: view} do
      assert has_element?(view, "#session-composer button[disabled]")
      assert render(view) =~ "box is offline."
    end

    test "stopping it queues the stop for when the node reconnects", %{view: view, session: s} do
      send(view.pid, :node_sessions_changed)
      render_click(view, "stop")
      assert has_element?(view, "#flash-info", "It stops this session when it reconnects.")

      assert [%{state: "queued"}] =
               Enum.filter(
                 Photon.Repo.all(Photon.NodeSessions.Input),
                 &(&1.session_id == s.id and &1.input["kind"] == "control")
               )
    end

    test "a message still goes into the outbox", %{view: view, session: s} do
      view |> form("#session-composer", message: %{text: "and the NAS?"}) |> render_submit()
      view |> form("#session-composer", message: %{text: "  "}) |> render_submit()

      assert [_, _] =
               Enum.filter(Photon.Repo.all(Photon.NodeSessions.Input), &(&1.session_id == s.id))
    end

    test "can be deleted", %{view: view, session: s} do
      assert {:error, {:live_redirect, %{to: "/"}}} =
               view |> element("#delete-session") |> render_click()

      assert NodeSessions.get(s.id) == nil
    end
  end

  describe "a session whose node comes online" do
    setup [:session_page, :node_online]

    test "can be messaged", %{view: view} do
      _ = render(view)
      refute has_element?(view, "#session-composer button[disabled]")
    end

    test "streams the agent's text and command output until records replace them", %{
      view: view,
      session: s
    } do
      send(view.pid, {:node_live, s.id, %{"type" => "text", "delta" => "Looking"}})
      assert render(view) =~ "Looking"

      asked =
        record("model_response", %{
          "response" => %{
            "message" =>
              PhotonCore.Message.assistant("Looking.", [call("Bash", %{"command" => "df"}, "c1")])
          }
        })

      :ok = NodeSessions.ingest(s.id, "box", 0, record("session", %{}))
      :ok = NodeSessions.ingest(s.id, "box", 1, asked)
      _ = render(view)

      send(
        view.pid,
        {:node_live, s.id, %{"type" => "op_output", "op" => "op1", "text" => "Filesystem"}}
      )

      assert has_element?(view, "#live-op1", "Filesystem")

      op = %{
        "id" => "op1",
        "type" => "shell",
        "status" => "completed",
        "state" => %{"result" => %{"out" => "plenty", "exit_code" => 0}}
      }

      :ok =
        NodeSessions.ingest(
          s.id,
          "box",
          2,
          record("tool_call_status", %{"call_id" => "c1", "operations" => [op]})
        )

      _ = render(view)

      refute has_element?(view, "#live-op1")
      assert has_element?(view, "#items", "plenty")
    end
  end
end
