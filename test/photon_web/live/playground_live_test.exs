defmodule PhotonWeb.PlaygroundLiveTest do
  use PhotonWeb.ConnCase

  import Phoenix.LiveViewTest

  setup do
    File.rm_rf!(Photon.Paths.data_dir())
    :ets.delete_all_objects(Photon.Sessions.counts_table())
    :ok
  end

  # Stands in for a connected node: registers this test process as its channel.
  defp fake_node(id, info \\ %{}) do
    info =
      Map.merge(
        %{
          "runner" => "/bin/runner",
          "key_envs" => [],
          "running" => MapSet.new(),
          "capabilities" => ["attachments"]
        },
        info
      )

    {:ok, _} = Registry.register(Photon.NodeRegistry, id, info)
    Photon.Nodes.broadcast()
  end

  test "renders the empty playground", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Try the Unreal Agent harness"
    assert has_element?(view, "select[name='settings[provider]']")
  end

  test "renders a stored session", %{conn: conn} do
    session = Photon.Sessions.create("Fixture", "local")

    events =
      "test/fixtures/mock_session.jsonl"
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    Photon.Sessions.append_events(session["id"], events)

    {:ok, view, html} = live(conn, ~p"/s/#{session["id"]}")
    assert html =~ "tick 2"
    assert html =~ "exit 3"
    assert html =~ "data:image/png;base64,"

    assert view |> element("button", "Raw events") |> render_click() =~ "model_response"
  end

  test "renders Markdown in resumed sessions and live response updates", %{conn: conn} do
    session = Photon.Sessions.create("Markdown", "local")

    event = fn text ->
      %{
        "Kind" => "model_response",
        "Data" => %{
          "Response" => %{
            "Output" => [
              %{"Type" => "message", "Data" => %{"Role" => "assistant", "Text" => text}}
            ]
          }
        }
      }
    end

    Photon.Sessions.append_events(session["id"], [event.("| A | B |\n|---|---|\n|one|two|")])
    {:ok, view, _html} = live(conn, ~p"/s/#{session["id"]}")
    assert has_element?(view, ".markdown-body table td", "one")

    Phoenix.PubSub.broadcast(
      Photon.PubSub,
      Photon.Sessions.topic(session["id"]),
      {:runner_event, session["id"], event.("> Updated *live*")}
    )

    assert has_element?(view, ".markdown-body blockquote em", "live")
    assert has_element?(view, ".markdown-body table td", "one")
  end

  test "persists settings changes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> form("#settings-form", settings: %{provider: "openrouter"}) |> render_change()
    assert Photon.Settings.load()["provider"] == "openrouter"
    assert render(view) =~ "OPENROUTER_API_KEY"
  end

  test "sends a message to the chosen node and follows its run state", %{conn: conn} do
    fake_node("local")
    {:ok, view, _html} = live(conn, ~p"/")
    refute render(view) =~ "is offline"

    view |> form("#composer-form", prompt: "$ echo hi") |> render_submit()

    assert_receive {:command, "start_run",
                    %{"session_id" => id, "prompt" => "$ echo hi", "config" => config}}

    assert config["provider"] == "mock"
    assert %{"node" => "local", "title" => "$ echo hi"} = Photon.Sessions.get(id)

    Registry.update_value(Photon.NodeRegistry, "local", &%{&1 | "running" => MapSet.new([id])})
    Photon.Nodes.broadcast()
    assert render(view) =~ "Running"

    view |> element("button[title^='Stop']") |> render_click()
    assert_receive {:command, "stop_run", %{"session_id" => ^id}}
  end

  test "shows sessions on an offline node as read-only", %{conn: conn} do
    session = Photon.Sessions.create("Remote", "gpu-box")
    {:ok, view, html} = live(conn, ~p"/s/#{session["id"]}")
    assert html =~ "is offline"
    assert has_element?(view, "#composer[disabled]")
    assert has_element?(view, "span", "gpu-box")
  end

  test "warns when the node has no runner, and reports its keys", %{conn: conn} do
    fake_node("local", %{"runner" => nil, "key_envs" => ["OPENROUTER_API_KEY"]})
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "has no"
    view |> form("#settings-form", settings: %{provider: "openrouter"}) |> render_change()
    assert render(view) =~ "is set on node local"
  end

  test "settings changed in one tab reach the others, and stale forms don't replay", %{conn: conn} do
    {:ok, tab1, _} = live(conn, ~p"/")
    {:ok, tab2, _} = live(conn, ~p"/")
    assert has_element?(tab2, "#settings-form[phx-auto-recover=ignore]")

    tab1 |> form("#settings-form", settings: %{provider: "openrouter"}) |> render_change()

    assert has_element?(
             tab2,
             "select[name='settings[provider]'] option[value=openrouter][selected]"
           )
  end

  @tag :tmp_dir
  test "lists tailnet machines and explains why installing is blocked", %{
    conn: conn,
    tmp_dir: dir
  } do
    status = %{
      "Self" => %{
        "DNSName" => "hub.example.ts.net.",
        "OS" => "linux",
        "TailscaleIPs" => ["100.64.0.1"]
      },
      "Peer" => %{
        "a" => %{
          "DNSName" => "box.example.ts.net.",
          "OS" => "linux",
          "Online" => true,
          "sshHostKeys" => ["k"]
        },
        "b" => %{"DNSName" => "phone.example.ts.net.", "OS" => "iOS", "Online" => true}
      }
    }

    tailscale = Path.join(dir, "tailscale")
    File.write!(tailscale, "#!/bin/sh\ncat <<'JSON'\n#{Jason.encode!(status)}\nJSON\n")
    File.chmod!(tailscale, 0o755)
    System.put_env("PHOTON_TAILSCALE", tailscale)
    on_exit(fn -> System.delete_env("PHOTON_TAILSCALE") end)

    {:ok, view, _html} = live(conn, ~p"/")
    html = view |> element("button[title='Connect a node']") |> render_click()

    assert html =~ "box"
    assert html =~ "Tailscale SSH"
    assert html =~ "not supported"
    # The test endpoint listens on loopback, so it points at the tailnet address.
    assert html =~ "PHOTON_BIND=100.64.0.1"
    assert has_element?(view, "button[phx-value-machine=box][disabled]", "Install")
    assert html =~ "/node/install.sh | PHOTON_NODE_TOKEN="
  end

  test "on a hub with no nodes, points at adding one", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "No nodes are connected yet."
    assert view |> element("button", "Add a node") |> render_click() =~ "Your tailnet"
  end

  test "new sessions fall back to a connected node when the chosen one is offline", %{conn: conn} do
    fake_node("box2")
    {:ok, view, html} = live(conn, ~p"/")
    refute html =~ "is offline"
    view |> form("#composer-form", prompt: "hi") |> render_submit()
    assert_receive {:command, "start_run", %{"session_id" => id}}
    assert %{"node" => "box2"} = Photon.Sessions.get(id)
  end

  test "sends attached images to the node and shows them in the conversation", %{conn: conn} do
    fake_node("local")
    {:ok, view, _html} = live(conn, ~p"/")
    png = <<137, 80, 78, 71, 13, 10, 26, 10, "not really a png">>

    image =
      file_input(view, "#composer-form", :images, [
        %{name: "cat pic.png", content: png, type: "image/png"}
      ])

    render_upload(image, "cat pic.png")
    assert has_element?(view, "#composer-form img")

    view |> form("#composer-form", prompt: "") |> render_submit()

    assert_receive {:command, "start_run",
                    %{"session_id" => id, "prompt" => prompt, "attachments" => [sent]}}

    assert Base.decode64!(sent["data"]) == png
    assert sent["path"] =~ ~r/\A\.attachments\/.*cat-pic\.png\z/
    assert Photon.Attachments.split(prompt) == {"", [sent["path"]]}

    name = Path.basename(sent["path"])
    assert {:ok, _} = Photon.Attachments.hub_file(id, name)
    assert get(conn, "/sessions/#{id}/attachments/#{name}").resp_body == png
    assert get(conn, "/sessions/#{id}/attachments/..%2Fmeta.json").status == 404

    # The runner echoes the message back as an input event; the bubble shows the image.
    Photon.Sessions.ingest(id, "local", 0, %{
      "Kind" => "input",
      "Data" => %{"Kind" => "external", "Payload" => prompt}
    })

    assert has_element?(view, "img[src='/sessions/#{id}/attachments/#{name}']")
    refute render(view) =~ "open them with ViewImage"
  end

  test "won't send images to a node too old to receive them", %{conn: conn} do
    fake_node("local", %{"capabilities" => nil})
    {:ok, view, _html} = live(conn, ~p"/")

    image =
      file_input(view, "#composer-form", :images, [
        %{name: "a.png", content: "png", type: "image/png"}
      ])

    render_upload(image, "a.png")

    html = view |> form("#composer-form", prompt: "look") |> render_submit()
    assert html =~ "needs an update to receive images"
    refute_received {:command, "start_run", _}
    assert has_element?(view, "#composer-form img")
  end

  @tag :tmp_dir
  test "flags out-of-date nodes in the sidebar, the conversation and the panel", %{
    conn: conn,
    tmp_dir: dir
  } do
    File.write!(Path.join(dir, "VERSION"), "0.1.0+20260923060000\n")
    Application.put_env(:photon, :node_dist_dir, dir)
    on_exit(fn -> Application.delete_env(:photon, :node_dist_dir) end)

    fake_node("local", %{"version" => "0.1.0+20260922000000"})
    fake_node("fresh", %{"version" => "0.1.0+20260923060000"})
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "Node <code class=\"font-mono\">local</code> is out of date."
    assert html =~ "this hub has 0.1.0+20260923060000"
    assert has_element?(view, "button[title^='This node is out of date']", "update")
    refute render(view) =~ "Node <code class=\"font-mono\">fresh</code> is out of date"

    # Picking the current node clears the banner; the sidebar badge stays on local.
    view |> element("#node-picker") |> render_change(%{"node" => "fresh"})
    refute render(view) =~ "Node <code class=\"font-mono\">local</code> is out of date."
    assert has_element?(view, "button[title^='This node is out of date']")
  end
end
