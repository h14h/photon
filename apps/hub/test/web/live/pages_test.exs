defmodule PhotonWeb.PagesTest do
  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :durable

  alias Photon.{Durable, NodeSessions}

  test "the assistant answers in the conversation", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#composer")
    assert has_element?(view, "#empty-state")

    conversation = Photon.Assistant.conversation_id()
    Durable.subscribe(conversation)

    view |> form("#composer", message: %{text: "help"}) |> render_submit()
    await_entry(conversation, &(&1.kind == "assistant"))

    _ = render(view)
    assert has_element?(view, "#entries [id^=entries-]")
    refute has_element?(view, "#empty-state")
  end

  test "the nodes page offers both ways to add a node", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/nodes")
    assert has_element?(view, "#add-node")
    assert has_element?(view, "#install-command")
  end

  test "settings save", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")
    refute has_element?(view, "#settings_api_key")

    view |> form("#settings-form", settings: %{provider: "fireworks"}) |> render_change()
    assert has_element?(view, "#settings_api_key")

    view
    |> form("#settings-form",
      settings: %{
        provider: "fireworks",
        model: "",
        api_key: "fw-test",
        timezone: "America/Chicago"
      }
    )
    |> render_submit()

    settings = Photon.Settings.load()
    assert settings["provider"] == "fireworks"
    assert settings["api_key"] == "fw-test"
    assert Photon.Settings.model(settings) == "accounts/fireworks/models/deepseek-v4p1-flash"
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
