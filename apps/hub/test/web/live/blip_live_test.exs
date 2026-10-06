defmodule PhotonWeb.BlipLiveTest do
  @moduledoc """
  Blip, floating over the pages, driven as a user would: the conversation
  (sending, the in-flight answer, the inbox while the assistant is busy),
  the panel, what Blip says while it's closed, and its mood.
  """

  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Photon.Fixtures, only: [call: 3]

  alias Photon.{Assistant, Durable}
  alias PhotonCore.Message

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
      blip |> form("#composer", message: %{text: "machines"}) |> render_submit()
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

    test "shows the web searches an answer runs, and keeps them with the answer", %{
      blip: blip,
      conversation: c
    } do
      send(blip.pid, {:live, c, %{"type" => "start"}})
      send(blip.pid, {:live, c, %{"type" => "web_search", "id" => "ws_1", "action" => nil}})
      assert has_element?(blip, "#live-searches [data-search]", "Searching the web")

      query = %{"type" => "search", "query" => "latest elixir"}
      send(blip.pid, {:live, c, %{"type" => "web_search", "id" => "ws_1", "action" => query}})
      assert has_element?(blip, "#live-searches", "Searched the web for")

      page = %{"type" => "open_page", "url" => "https://github.com/elixir-lang/elixir/releases"}

      message =
        "v1.20.4."
        |> PhotonCore.Message.assistant()
        |> Map.put("reasoning_items", [
          %{"type" => "web_search_call", "id" => "ws_1", "action" => query},
          %{"type" => "web_search_call", "id" => "ws_2", "action" => page}
        ])

      Durable.commit(&Durable.Tx.append(&1, c, "assistant", %{"message" => message}))
      refute has_element?(blip, "#live-searches")
      assert has_element?(blip, "#entries [data-search]", "latest elixir")

      assert has_element?(
               blip,
               ~s(#entries [data-search] a[href="https://github.com/elixir-lang/elixir/releases"]),
               "Read github.com/elixir-lang/elixir/releases"
             )
    end

    test "a blank message sends nothing", %{blip: blip, conversation: c} do
      blip |> form("#composer", message: %{text: "   "}) |> render_submit()
      assert Durable.entries(c) == []
    end

    test "shows the in-flight answer until it is committed", %{blip: blip, conversation: c} do
      send(blip.pid, {:live, c, %{"type" => "start"}})
      send(blip.pid, {:live, c, %{"type" => "text", "delta" => "Working on it"}})
      # Nothing shows until a paragraph is finished; then only finished ones.
      refute has_element?(blip, "#live-text")
      assert has_element?(blip, "#live-output [aria-label=Thinking]")

      send(blip.pid, {:live, c, %{"type" => "text", "delta" => ".\n\nMore to co"}})
      assert has_element?(blip, "#live-text[data-streaming]", "Working on it.")
      refute has_element?(blip, "#live-text", "More to co")

      send(
        blip.pid,
        {:live, c, %{"type" => "retry", "delay_ms" => 2000, "message" => "HTTP 503"}}
      )

      assert has_element?(blip, "#live-output", "Trying again in 2.0s")
    end
  end

  describe "a call on a machine" do
    setup [:page, :opened]

    # Blip's answer making `calls`, as the model's tool calls.
    defp asked(c, calls) do
      calls = for {id, name, args} <- calls, do: call(name, args, id)

      Durable.commit(
        &Durable.Tx.append(&1, c, "assistant", %{"message" => Message.assistant("", calls)})
      )
    end

    defp answered(c, call_id, name, content, details) do
      Durable.commit(
        &Durable.Tx.append(&1, c, "tool_result", %{
          "message" => Message.tool_result(call_id, content),
          "name" => name,
          "status" => "ok",
          "details" => details
        })
      )
    end

    # Output from the call, as `Photon.Machines` passes on a node's `op.output`.
    defp printed(c, call_id, stream, text) do
      Durable.live(c, %{
        "type" => "tool_output",
        "call_id" => call_id,
        "stream" => stream,
        "text" => text
      })
    end

    test "shows what it ran and where, and streams its output until the result comes", %{
      blip: blip,
      conversation: c
    } do
      asked(c, [{"c1", "shell", %{"machine" => "mm1", "command" => "make test"}}])

      assert has_element?(blip, "#action-c1[data-tool=shell][data-status=pending]")
      assert has_element?(blip, "#action-c1 summary code", "make test")
      assert has_element?(blip, "#action-c1 summary", "Running make test on mm1")
      refute has_element?(blip, "#action-c1-tail")

      printed(c, "c1", "out", "compiling\n")
      printed(c, "c1", "err", "1 warning\n")

      assert has_element?(blip, "#action-c1-tail pre", ~r/compiling\s+1 warning/)
      # Each output chunk re-renders the answer; an opened result stays open.
      assert has_element?(blip, "#action-c1-details[phx-mounted*=ignore_attrs]")

      answered(c, "c1", "shell", "compiling\nStderr:\n1 warning\nExit code: 2", %{
        "machine" => "mm1",
        "kind" => "shell",
        "status" => "completed",
        "command" => "make test",
        "exit_code" => 2
      })

      refute has_element?(blip, "#action-c1-tail")
      assert has_element?(blip, "#action-c1[data-status=done]")
      assert has_element?(blip, "#action-c1 summary", "Ran make test on mm1")
      refute has_element?(blip, "#action-c1 summary", "Running")
      assert has_element?(blip, "#action-c1 summary", "exit 2")
      assert has_element?(blip, "#action-c1 details pre", "Exit code: 2")

      # Output that comes after the result has nowhere to go.
      printed(c, "c1", "out", "late")

      refute has_element?(blip, "#action-c1-tail")
    end

    test "shows the image a view_image call returns, loaded on its own", %{
      blip: blip,
      conversation: c
    } do
      asked(c, [{"c2", "view_image", %{"machine" => "mm1", "path" => "shot.png"}}])
      assert has_element?(blip, "#action-c2 summary", "Looking at shot.png on mm1")

      result =
        answered(
          c,
          "c2",
          "view_image",
          [
            Message.image("image/png", "iVBORw0KGgo="),
            Message.text("1x1 image/png, /home/me/shot.png on mm1")
          ],
          %{
            "machine" => "mm1",
            "kind" => "view_image",
            "status" => "completed",
            "path" => "shot.png"
          }
        )

      assert has_element?(blip, "#action-c2 summary", "Looked at shot.png on mm1")
      src = "/blip/images/#{result.id}/0"
      assert has_element?(blip, ~s(#action-c2 img#action-c2-image-0[src="#{src}"]))
      # The page carries no image data, so a re-render of the answer sends none.
      refute render(blip) =~ "iVBORw0KGgo="

      conn = get(build_conn(), src)
      assert response(conn, 200) == Base.decode64!("iVBORw0KGgo=")
      assert get_resp_header(conn, "content-type") == ["image/png"]

      assert has_element?(
               blip,
               "#action-c2-image-0[alt='1x1 image/png, /home/me/shot.png on mm1']"
             )
    end

    test "a call on the hub's own machine names it too", %{blip: blip, conversation: c} do
      asked(c, [{"c6", "shell", %{"machine" => "local", "command" => "uname -a"}}])
      assert has_element?(blip, "#action-c6 summary", "Running uname -a on local")

      answered(c, "c6", "shell", "Linux", %{
        "machine" => "local",
        "kind" => "shell",
        "status" => "completed",
        "command" => "uname -a",
        "exit_code" => 0
      })

      assert has_element?(blip, "#action-c6[data-status=done] summary", "Ran uname -a on local")

      # A call whose arguments don't name the machine takes it from the result.
      asked(c, [{"c7", "view_image", %{"path" => "shot.png"}}])

      answered(c, "c7", "view_image", "1x1 image/png", %{
        "machine" => "local",
        "kind" => "view_image",
        "status" => "completed",
        "path" => "shot.png"
      })

      assert has_element?(blip, "#action-c7 summary", "Looked at shot.png on local")
    end

    test "a failed or canceled operation shows as such, named from the call", %{
      blip: blip,
      conversation: c
    } do
      asked(c, [
        {"c3", "shell", %{"machine" => "mm1", "command" => "false"}},
        {"c4", "shell", %{"machine" => "mm2", "command" => "sleep 99"}},
        {"c5", "list_machines", %{}}
      ])

      # An error result carries no details: the line comes from the arguments.
      Durable.commit(
        &Durable.Tx.append(&1, c, "tool_result", %{
          "message" => Message.tool_result("c3", "mm1 runs an older photon-node"),
          "name" => "shell",
          "status" => "error",
          "details" => %{}
        })
      )

      answered(c, "c4", "shell", "Error: canceled", %{"kind" => "shell", "status" => "canceled"})
      answered(c, "c5", "list_machines", "mm1, online", %{})

      assert has_element?(blip, "#action-c3[data-status=error]", "Ran false on mm1")
      assert has_element?(blip, "#action-c4[data-status=stopped]", "Ran sleep 99 on mm2")
      assert has_element?(blip, "#action-c5[data-status=done]", "Checked your machines")
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

    test "Blip says its answer's first paragraph, whole, in a bubble, and counts it unread", %{
      blip: blip,
      conversation: c
    } do
      refute has_element?(blip, "[data-bubble]")
      Assistant.send("help")
      await_entry(c, &(&1.kind == "assistant"))

      assert has_element?(
               blip,
               "#blip-bubbles [data-bubble]",
               "I'm Blip, on the scripted model, so I only follow a few fixed phrasings:"
             )

      refute has_element?(blip, "#blip-bubbles", "lists your machines")
      assert has_element?(blip, "#blip-unread", "1")
    end

    test "a new bubble pushes the last one up and out", %{blip: blip, conversation: c} do
      Durable.commit(&Durable.Tx.append(&1, c, "error", %{"message" => "HTTP 401"}))
      [first] = bubbles(blip)

      Durable.commit(&Durable.Tx.append(&1, c, "error", %{"message" => "HTTP 500"}))
      assert has_element?(blip, "#bubble-#{first}.is-leaving", "HTTP 401")
      assert has_element?(blip, "[data-bubble]:not(.is-leaving)", "HTTP 500")
      assert has_element?(blip, "#blip-unread", "2")

      # Once it has faded, it goes.
      send(blip.pid, {:bubble_gone, first})
      refute has_element?(blip, "#bubble-#{first}")
    end

    test "a bubble can be dismissed, or all of them", %{blip: blip, conversation: c} do
      Durable.commit(&Durable.Tx.append(&1, c, "error", %{"message" => "HTTP 401"}))
      [id] = bubbles(blip)

      # The × (and a bubble's time running out) sends this from the hook.
      assert has_element?(blip, "#bubble-#{id} [data-bubble-dismiss='#{id}']")
      render_hook(blip, "dismiss_bubble", %{"id" => id})

      assert has_element?(blip, "#bubble-#{id}.is-leaving")

      Durable.commit(&Durable.Tx.append(&1, c, "error", %{"message" => "HTTP 500"}))
      render_hook(blip, "dismiss_bubbles", %{})
      refute has_element?(blip, "[data-bubble]:not(.is-leaving)")
      # Dismissed isn't read: the count waits for the chat.
      assert has_element?(blip, "#blip-unread", "2")
    end

    test "opening the panel reads what was unread", %{blip: blip, conversation: c} do
      Durable.commit(&Durable.Tx.append(&1, c, "error", %{"message" => "HTTP 401"}))
      assert has_element?(blip, "[data-bubble].is-failed", "HTTP 401")

      render_hook(blip, "panel", %{"to" => "open"})
      refute has_element?(blip, "[data-bubble]")
      refute has_element?(blip, "#blip-unread")
    end

    test "a stopped run says nothing", %{blip: blip, conversation: c} do
      Durable.commit(
        &Durable.Tx.append(&1, c, "error", %{"message" => "Stopped.", "stopped" => true})
      )

      refute has_element?(blip, "[data-bubble]")
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
  end

  # The IDs of the bubbles Blip is showing, oldest first.
  defp bubbles(blip) do
    blip
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-bubble]")
    |> LazyHTML.attribute("data-bubble")
  end

  # How many Blips the whole page draws.
  defp blips(view) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("svg.blip") |> Enum.count()
  end
end
