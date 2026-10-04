defmodule PhotonWeb.PagesTest do
  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :durable

  alias Photon.{Durable, NodeSessions}

  test "the overview shows machines, work and schedules", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#no-machines")
    assert has_element?(view, "#running", "Nothing running")
    assert has_element?(view, "#nav-overview")
  end

  test "Blip answers in the conversation over the page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    blip = find_live_child(view, "blip")
    assert has_element?(blip, "#composer")
    assert has_element?(blip, "#empty-state")

    conversation = Photon.Assistant.conversation_id()
    Durable.subscribe(conversation)

    blip |> form("#composer", message: %{text: "help"}) |> render_submit()
    await_entry(conversation, &(&1.kind == "assistant"))

    _ = render(blip)
    assert has_element?(blip, "#entries [id^=entries-]")
    refute has_element?(blip, "#empty-state")
  end

  test "the nodes page offers both ways to add a node", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/nodes")
    assert has_element?(view, "#add-node")
    assert has_element?(view, "#manual-key-form")
  end

  test "settings save", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#settings-form", settings: %{timezone: "America/Chicago", user_name: "Henry"})
    |> render_submit()

    settings = Photon.Settings.load()
    assert settings["timezone"] == "America/Chicago"
    assert settings["user_name"] == "Henry"
  end

  test "a node session shows its commands and output", %{conn: conn} do
    {:ok, session, input} = NodeSessions.start("box", "list files")
    call = %{"id" => "c1", "name" => "Bash", "arguments" => ~s({"command":"ls"})}

    op = %{
      "id" => "op",
      "type" => "shell",
      "status" => "completed",
      "state" => %{"result" => %{"out" => "a.txt\n", "err" => "", "exit_code" => 0}}
    }

    records = [
      %{"kind" => "session", "data" => %{}},
      %{
        "kind" => "input",
        "data" => %{
          "id" => input.id,
          "kind" => "external",
          "payload" => %{"content" => "list files"}
        }
      },
      %{
        "kind" => "model_response",
        "data" => %{
          "turn_id" => "t",
          "response" => %{"message" => PhotonCore.Message.assistant("Listing.", [call])}
        }
      },
      %{
        "kind" => "tool_call_status",
        "data" => %{
          "call_id" => "c1",
          "status" => %{"error" => "", "waiting_for" => ["op"]},
          "operations" => [op]
        }
      }
    ]

    for {r, i} <- Enum.with_index(records), do: :ok = NodeSessions.ingest(session.id, "box", i, r)

    {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}")
    assert html =~ "$ ls"
    assert html =~ "a.txt"
    assert has_element?(view, "#session-composer")
  end
end
