defmodule PhotonWeb.PagesTest do
  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :durable

  alias Photon.{Durable, Machines, NodeKeys, Projects, Schedules, Skills}

  test "the overview shows machines and schedules", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#no-machines")
    assert has_element?(view, "#schedules")
    assert has_element?(view, "#nav-home")
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

  test "no page links to node sessions, which are gone", %{conn: conn} do
    {:ok, _key} = NodeKeys.issue("nas")
    :ok = Machines.register("box", %{"hostname" => "box.lan", "platform" => "linux"})

    for path <- [~p"/", ~p"/nodes", ~p"/settings"] do
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, "#nav-machines[href='/nodes']", "1 online")
      refute has_element?(view, ~s(a[href^="/sessions"]))
      refute has_element?(find_live_child(view, "blip"), ~s(a[href^="/sessions"]))
    end

    assert get(conn, "/sessions/ns_1").status == 404
  end

  describe "the skills and schedule pages" do
    setup do
      {:ok, garden} =
        Projects.create(%{"purpose" => "Keep the garden watered.", "name" => "Garden"})

      {:ok, house} =
        Projects.create(%{"purpose" => "Keep the house in order.", "name" => "House"})

      {:ok, skill} =
        Skills.create(%{
          "name" => "pdf-forms",
          "description" => "Fill in PDF forms.",
          "instructions" => "Read the form first."
        })

      at = DateTime.utc_now() |> DateTime.add(1, :hour) |> DateTime.to_iso8601()

      {:ok, schedule} =
        Schedules.create({:project, garden.id}, %{
          "prompt" => "Check the backups",
          "at" => at,
          "repeat" => "once",
          "target" => "new_thread"
        })

      %{garden: garden, house: house, skill: skill, schedule: schedule}
    end

    test "each mounts with its heading", %{conn: conn, schedule: schedule} do
      for {path, selector, text} <- [
            {~p"/skills", "#skills-heading", "Skills"},
            {~p"/skills/new", "#skill-heading", "Write a skill"},
            {~p"/skills/install", "#install-heading", "Install a skill"},
            {~p"/skills/pdf-forms", "#skill-heading", "pdf-forms"},
            {~p"/projects/garden/schedules/new", "#schedule-heading", "New schedule"},
            {~p"/projects/garden/schedules/#{schedule.id}", "#schedule-heading", "Schedule"}
          ] do
        {:ok, view, _html} = live(conn, path)
        assert has_element?(view, selector, text), "#{path} has no #{selector}"
      end
    end

    test "the Skills page links to writing and installing one", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/skills")
      assert has_element?(view, "#new-skill[href='/skills/new']")
      assert has_element?(view, "#install-skill[href='/skills/install']")
    end

    test "a skill's page opens it in the editor; the schedule page shows its prompt and project",
         %{conn: conn, schedule: schedule} do
      {:ok, view, _html} = live(conn, ~p"/skills/pdf-forms")
      assert view |> element("#skill-description") |> render() =~ "Fill in PDF forms."
      assert has_element?(view, "#skill-back[href='/skills']")

      {:ok, view, _html} = live(conn, ~p"/projects/garden/schedules/#{schedule.id}")
      assert view |> element("#schedule-prompt") |> render() =~ "Check the backups"
      assert has_element?(view, "#schedule-project[href='/projects/garden']", "Garden")
      assert has_element?(view, "#side-project-garden.font-medium")
    end

    test "a missing skill goes back to the Skills page with a flash", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/skills", flash: flash}}} =
               live(conn, ~p"/skills/pdf-form")

      assert flash["error"] == "There's no skill called pdf-form."
    end

    test "a missing project or schedule goes home with a flash",
         %{conn: conn, schedule: schedule} do
      for {path, message} <- [
            {~p"/projects/nowhere/schedules/new", "There's no project called nowhere."},
            {~p"/projects/nowhere/schedules/#{schedule.id}",
             "There's no project called nowhere."},
            {~p"/projects/garden/schedules/sc_missing", "There's no such schedule in Garden."},
            {~p"/projects/house/schedules/#{schedule.id}", "There's no such schedule in House."}
          ] do
        assert {:error, {:live_redirect, %{to: "/", flash: flash}}} = live(conn, path)
        assert flash["error"] == message
      end
    end
  end
end
