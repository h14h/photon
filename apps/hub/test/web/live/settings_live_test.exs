defmodule PhotonWeb.SettingsLiveTest do
  @moduledoc """
  The settings page: signing in with ChatGPT (against a stub of OpenAI's
  endpoints), the model choices once signed in, ambient mode, what Blip
  knows about the user, and what Blip remembers.

  Ambient mode's section shows whenever Blip can think, so its tests run
  on the scripted model, where its run-now buttons show too. Its
  `#ambient-needs-consent` warning and the hidden section can't show
  there; their conditions are `PhotonWeb.AmbientText.needs_consent?/1` and
  `Photon.Ambient.Rules.config/2`, tested in core. Threads run on the
  scripted model: `files` finishes, `fail:` fails.
  """

  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import Ecto.Query, only: [from: 2]
  import Photon.ConversationHelpers
  import Photon.ProjectHelpers
  import PhotonWeb.LiveHelpers

  alias Photon.{
    Ambient,
    Assistant,
    ChatGPT,
    ChatGPTStub,
    Durable,
    Repo,
    Schedules,
    Signals,
    Threads
  }

  alias Photon.Durable.Tx
  alias Photon.Schedules.Routine
  alias Photon.Threads.Thread

  @moduletag :durable

  setup %{conn: conn} do
    # Against the real sign-in: with the scripted model on, the sidebar's
    # sign-in banner never shows.
    Photon.TestConfig.put_env(:photon, :mock_model, false)
    ChatGPTStub.reset!()
    # Signed in is saved to a file, so a test that signs in would leave the
    # next test, on any page, signed in without a stub to answer it.
    on_exit(&ChatGPTStub.reset!/0)
    {:ok, view, _html} = live(conn, ~p"/settings")
    %{view: view}
  end

  defp query(url), do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

  describe "signed out" do
    test "offers Sign in with ChatGPT and nothing about models", %{view: view} do
      assert has_element?(view, "#begin-sign-in")
      refute has_element?(view, "#settings_model")
      assert has_element?(view, "#sign-in-banner")
    end

    test "signing in is: open ChatGPT, then paste the address you land on", %{view: view} do
      view |> element("#begin-sign-in") |> render_click()
      assert has_element?(view, "#sign-in-steps")

      href = view |> element("#open-sign-in") |> render() |> LazyHTML.from_fragment()
      [url] = LazyHTML.attribute(href, "href")
      assert String.starts_with?(url, "https://auth.openai.com/api/accounts/authorize?")
      query = query(url)

      view
      |> form("#finish-sign-in", sign_in: %{address: "?code=c&state=wrong"})
      |> render_submit()

      assert has_element?(view, "#sign-in-error", "different sign-in")
      # The pasted address carries a code, so the page doesn't keep it.
      refute inspect(:sys.get_state(view.pid)) =~ "code=c&state=wrong"

      ChatGPTStub.answer(%{
        "/api/accounts/oauth/token" => fn _ ->
          {200, ChatGPTStub.tokens("oaiapp_1", %{"nonce" => query["nonce"]})}
        end,
        "/v1/models" => fn _ ->
          {200, %{"models" => [%{"slug" => "gpt-6-luna", "display_name" => "GPT-6 Luna"}]}}
        end
      })

      address =
        query["redirect_uri"] <>
          "?" <> URI.encode_query(code: "c1", state: query["state"], client_id: "oaiapp_1")

      view |> form("#finish-sign-in", sign_in: %{address: address}) |> render_submit()

      assert has_element?(view, "#flash-info", "Signed in with ChatGPT")
      assert has_element?(view, "#chatgpt-account", "henry@example.com")
      refute has_element?(view, "#sign-in-banner")
      assert has_element?(view, "#settings_model option[value=gpt-6-luna]", "GPT-6 Luna")
    end

    test "a sign-in can be cancelled", %{view: view} do
      view |> element("#begin-sign-in") |> render_click()
      render_click(view, "cancel_sign_in")
      refute has_element?(view, "#sign-in-steps")
      assert %{signing_in: false} = ChatGPT.status()
    end
  end

  describe "signed in" do
    setup %{view: view} do
      ChatGPTStub.sign_in!()
      _ = render(view)
      :ok
    end

    test "picks a model and an effort, and asks before scheduled work", %{view: view} do
      view
      |> form("#settings-form",
        settings: %{model: "gpt-6.1-sol", reasoning: "high", scheduled_work: "true"}
      )
      |> render_submit()

      settings = Photon.Settings.load()
      assert %{"model" => "gpt-6.1-sol", "reasoning" => "high"} = settings
      assert Photon.Settings.scheduled_work?(settings)
    end

    test "the scheduled-work checkbox speaks for every schedule, not only Blip's", %{view: view} do
      label = ~s{label:has(input[type=checkbox][name="settings[scheduled_work]"])}

      assert has_element?(view, label, "Let schedules use my plan while I'm away")
      refute has_element?(view, label, "Blip")
      assert has_element?(view, "#scheduled-work-hint", "your projects' schedules")
      assert has_element?(view, "#scheduled-work-hint", "the project page shows it")
    end

    test "signing out stops Blip until the next sign-in", %{view: view} do
      ChatGPTStub.answer(%{"/api/accounts/oauth/revoke" => fn _ -> {200, %{}} end})
      view |> element("#sign-out") |> render_click()

      assert has_element?(view, "#begin-sign-in")
      assert has_element?(view, "#sign-in-banner")
    end
  end

  test "saves the name Blip calls you", %{view: view} do
    view |> form("#settings-form", settings: %{user_name: "  Henry  "}) |> render_submit()
    assert Photon.Settings.load()["user_name"] == "Henry"
    assert has_element?(view, "#settings_user_name[value=Henry]")
  end

  describe "what Blip remembers" do
    test "can be edited, or the edit cancelled", %{view: view} do
      view |> element("#edit-memory") |> render_click()
      assert has_element?(view, "#memory-form")
      render_click(view, "cancel_memory")
      refute has_element?(view, "#memory-form")

      view |> element("#edit-memory") |> render_click()
      view |> form("#memory-form", memory: "  likes tea  ") |> render_submit()
      assert Photon.Assistant.memory() == "likes tea"
      assert has_element?(view, "#memory-text", "likes tea")
    end

    test "shows what Blip saves", %{view: view} do
      assert has_element?(view, "#memory-text", "Empty")
      Photon.Assistant.put_memory("the NAS is mp1")
      assert has_element?(view, "#memory-text", "the NAS is mp1")
    end

    test "a fresh context keeps the history and marks the break", %{view: view} do
      conversation = Photon.Assistant.conversation_id()
      Photon.Durable.subscribe(conversation)

      view |> element("#fresh-start") |> render_click()
      await_entry(conversation, &(&1.kind == "reset"))
      assert has_element?(view, "#flash-info", "fresh context")
    end
  end

  describe "ambient mode" do
    setup %{conn: conn} do
      # Blip thinks on the scripted model, so the section shows.
      Photon.TestConfig.put_env(:photon, :mock_model, true)
      {:ok, view, _html} = live(conn, ~p"/settings")

      project = garden!()

      %{view: view, project: project, blip: Assistant.conversation_id()}
    end

    defp save(view, settings),
      do: view |> form("#settings-form", settings: settings) |> render_submit()

    # Blip answers what a button sent it; the test waits for the answer, so
    # nothing runs on after it.
    defp answered!(blip) do
      _reply = await_entry(blip, &(&1.kind == "assistant"))
      idle!(blip)
    end

    test "shows its switch, interval and run-now buttons, and no status while off", %{
      view: view
    } do
      assert has_element?(view, "#ambient h2", "Ambient mode")

      assert has_element?(
               view,
               ~s{label:has(#settings_ambient)},
               "Let Blip follow along and speak up"
             )

      refute has_element?(view, "#settings_ambient[checked]")
      assert has_element?(view, "#ambient-hint", "a run on your ChatGPT plan")
      assert has_element?(view, "#settings_ambient_every option[value='180'][selected]")
      assert has_element?(view, "#settings_utc_offset[phx-hook][phx-update=ignore]")
      assert has_element?(view, "#ambient-digest-now", "Send a digest now")
      assert has_element?(view, "#ambient-review-now", "Run the review now")
      refute has_element?(view, "#ambient-state")
      refute has_element?(view, "#ambient-needs-consent")
    end

    test "ticking it and saving turns it on, and later saves keep it on", %{view: view} do
      save(view, %{ambient: "true"})

      assert Ambient.status().on?
      assert has_element?(view, "#ambient-state #ambient-next", "Next digest around")
      assert has_element?(view, "#ambient-next-digest-at")
      assert has_element?(view, "#ambient-next-review-at")
      assert has_element?(view, "#ambient-pending", "Nothing new yet.")
      assert has_element?(view, "#ambient-on")
      # The form is rebuilt with the saved switch, so the box stays ticked
      # and the next Save sends it back.
      assert has_element?(view, "#settings_ambient[checked]")

      save(view, %{user_name: "Henry"})
      assert Photon.Settings.load()["user_name"] == "Henry"
      assert Ambient.status().on?
      assert has_element?(view, "#settings_ambient[checked]")
    end

    test "a save without the switch, as when the section is hidden, leaves it on", %{view: view} do
      save(view, %{ambient: "true"})
      render_submit(view, "save", %{"settings" => %{"user_name" => "Henry"}})

      assert Ambient.status().on?
      assert has_element?(view, "#ambient-state")
    end

    test "a new interval is saved, still on", %{view: view} do
      save(view, %{ambient: "true"})
      save(view, %{ambient_every: "60"})

      assert %{on?: true, every_minutes: 60} = Ambient.status()
      assert has_element?(view, "#settings_ambient_every option[value='60'][selected]")
    end

    test "the browser's UTC offset reaches the setting", %{view: view} do
      view
      |> element("#settings-form")
      |> render_submit(%{settings: %{ambient: "true", utc_offset: "-300"}})

      assert Signals.ambient_doc()["offset_minutes"] == -300
    end

    test "unticking it and saving turns it off and hides the status", %{view: view} do
      save(view, %{ambient: "true"})
      assert has_element?(view, "#ambient-state")

      save(view, %{ambient: "false"})
      refute Ambient.status().on?
      refute has_element?(view, "#ambient-state")
      refute has_element?(view, "#settings_ambient[checked]")
    end

    test "sending a digest with nothing new says so", %{view: view} do
      save(view, %{ambient: "true"})
      view |> element("#ambient-digest-now") |> render_click()

      assert has_element?(view, "#flash-info", "Nothing new since the last digest.")
      assert has_element?(view, "#ambient-last-digest", "nothing new, skipped.")
      assert has_element?(view, "#ambient-last-digest-at")
    end

    test "a run-now button while it is off asks to turn it on first", %{view: view} do
      view |> element("#ambient-digest-now") |> render_click()
      assert has_element?(view, "#flash-error", "Turn on ambient mode first.")
      refute has_element?(view, "#flash-info")
    end

    test "sending a digest with a finished thread sends it to Blip", %{
      view: view,
      project: project,
      blip: blip
    } do
      save(view, %{ambient: "true"})
      _thread = idle_thread!(project, "files")
      :ok = Durable.subscribe(blip)
      view |> element("#ambient-digest-now") |> render_click()

      assert has_element?(view, "#flash-info", "Sent Blip a digest of 2 changes.")
      assert has_element?(view, "#ambient-last-digest", "sent 2 changes.")
      assert has_element?(view, "#ambient-pending", "Nothing new yet.")
      answered!(blip)
    end

    test "running the review sends Blip the threads left untouched", %{
      view: view,
      project: project,
      blip: blip
    } do
      save(view, %{ambient: "true"})
      view |> element("#ambient-review-now") |> render_click()
      assert has_element?(view, "#flash-info", "No threads need a review.")

      thread = idle_thread!(project, "fail: the ladder is missing").id
      at = DateTime.add(DateTime.utc_now(), -4 * 86_400, :second)
      query = from(t in Thread, where: t.id == ^thread)
      {1, _rows} = Repo.update_all(query, set: [last_run_ended_at: at, active_at: at])

      # The failure reached Blip as an update; the review goes once Blip is
      # done with it, rather than queueing behind it.
      idle!(blip)
      view |> element("#ambient-review-now") |> render_click()

      assert has_element?(view, "#flash-info", "Sent Blip a review of 1 thread.")
      assert has_element?(view, "#ambient-last-review", "sent 1 thread.")
      answered!(blip)
    end

    test "what is waiting follows threads finishing and being seen elsewhere", %{
      view: view,
      project: project
    } do
      save(view, %{ambient: "true"})
      assert has_element?(view, "#ambient-pending", "Nothing new yet.")

      thread = idle_thread!(project, "files").id
      settled(view)

      assert has_element?(
               view,
               "#ambient-pending",
               "1 change waiting, and 1 you've seen or made yourself."
             )

      assert Threads.mark_seen(thread) == :ok
      settled(view)

      assert has_element?(
               view,
               "#ambient-pending",
               "Nothing new yet. 2 changes you've seen or made yourself wait for the next " <>
                 "digest with something new."
             )
    end

    test "signed out while it is on, it shows only the switch, and can be turned off", %{
      conn: conn
    } do
      :ok = Ambient.configure(%{"ambient" => "true"})
      Photon.TestConfig.put_env(:photon, :mock_model, false)
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#ambient #settings_ambient[checked]")

      assert has_element?(
               view,
               "#ambient-needs-model",
               "Blip isn't signed in to ChatGPT, so digests and reviews skip"
             )

      assert has_element?(view, "#ambient-state")
      refute has_element?(view, "#settings_ambient_every")
      refute has_element?(view, "#settings_utc_offset")
      refute has_element?(view, "#ambient-try")
      refute has_element?(view, "#ambient-needs-consent")

      save(view, %{ambient: "false"})
      refute Ambient.status().on?
      # Off and signed out: nothing left to show.
      refute has_element?(view, "#ambient")
    end

    test "a schedule that stops is a change waiting", %{view: view, project: project} do
      save(view, %{ambient: "true"})

      {:ok, schedule} =
        Schedules.create({:project, project.id}, %{
          "prompt" => "Check the gutters",
          "at" => DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601(),
          "repeat" => "every",
          "every" => "1",
          "unit" => "days",
          "target" => "new_thread"
        })

      task = Durable.task(schedule.task_id)

      :ok =
        Durable.commit(fn tx ->
          _failed = Tx.finish(tx, task, "failed", %{"status" => "failed", "reason" => "boom"})
          Routine.on_fail(task, "boom", tx)
        end)

      settled(view)
      assert has_element?(view, "#ambient-pending", "1 change waiting.")
    end
  end
end
