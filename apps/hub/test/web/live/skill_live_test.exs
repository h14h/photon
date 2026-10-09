defmodule PhotonWeb.SkillLiveTest do
  @moduledoc """
  A skill's page: writing one, editing and renaming it, the stale-save
  banner, the switches that turn it on (for Blip, projects and machines),
  deleting it, and what the page does when the skill or the machines
  change elsewhere.

  Writes from the test process are other processes' writes as far as the
  page is concerned. The Store broadcasts inside the commit's call, so
  the page has the announcement queued before the test's next render.
  """

  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Photon.ProjectHelpers

  alias Photon.{NodeKeys, Projects, Skills}

  @moduletag :durable

  setup do
    garden = garden!()

    {:ok, skill} =
      Skills.create(%{
        "name" => "pdf-forms",
        "description" => "Fill in PDF forms.",
        "instructions" => "# PDF forms\n\nRead the form first."
      })

    %{garden: garden, skill: skill}
  end

  defp open(conn), do: live(conn, ~p"/skills/pdf-forms")

  defp field(view, selector), do: view |> element(selector) |> render()

  defp type(view, params), do: view |> form("#skill-form", skill: params) |> render_change()

  describe "writing a skill" do
    test "the page mounts with an empty form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/skills/new")
      assert field(view, "#skill-heading") =~ "Write a skill"
      assert has_element?(view, "#skill-form #skill-name")
      assert has_element?(view, "#skill-form #skill-description")
      assert has_element?(view, ~s(#skill-form #skill-instructions[phx-debounce="400"]))
      assert has_element?(view, ~s(#skill-form[data-dirty="false"]))

      # The context file editor's guard, shared.
      assert has_element?(
               view,
               ~s(#skill-form[phx-hook="PhotonWeb.EditorComponents.UnsavedGuard"])
             )

      refute has_element?(view, "#skill-delete")
      refute has_element?(view, "#skill-meta")
      refute has_element?(view, "#skill-scope-blip")
    end

    test "is created through the form and lands on its page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/skills/new")

      type(view, %{name: "release-notes"})
      assert has_element?(view, ~s(#skill-form[data-dirty="true"]))
      assert has_element?(view, "#skill-dirty")

      {:ok, view, html} =
        view
        |> form("#skill-form",
          skill: %{
            name: "release-notes",
            description: "Write release notes.",
            instructions: "List the changes."
          }
        )
        |> render_submit()
        |> follow_redirect(conn, ~p"/skills/release-notes")

      assert html =~ "Saved release-notes. It&#39;s off everywhere; turn it on below."
      assert field(view, "#skill-heading") =~ "release-notes"
      assert field(view, "#skill-meta") =~ "Version 1."
      assert field(view, "#skill-meta") =~ "Written here."
      assert has_element?(view, ~s(#skill-scope-blip[aria-checked="false"]))

      skill = Skills.get_by_name("release-notes")
      assert %{description: "Write release notes.", instructions: "List the changes."} = skill
      assert Skills.scopes(skill.id) == []
    end

    test "a bad name shows the rule and keeps the text", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/skills/new")

      html =
        view
        |> form("#skill-form",
          skill: %{name: "PDF Forms", description: "Fill.", instructions: "Read it."}
        )
        |> render_submit()

      assert html =~ "A skill&#39;s name uses lowercase letters, digits and hyphens"
      assert field(view, "#skill-instructions") =~ "Read it."
      assert Enum.map(Skills.list(), & &1.skill.name) == ["pdf-forms"]
    end

    test "a name another skill has says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/skills/new")

      html =
        view
        |> form("#skill-form", skill: %{name: "pdf-forms", description: "A.", instructions: "B."})
        |> render_submit()

      assert html =~ "There&#39;s already a skill called pdf-forms."
    end

    test "the Preview tab shows the instructions as Markdown", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/skills/new")
      type(view, %{instructions: "# Steps\n\n1. Read the form."})

      view |> element("#skill-tab-preview") |> render_click()
      assert has_element?(view, ~s(#skill-tab-preview[aria-selected="true"]))
      assert has_element?(view, "#skill-preview h1", "Steps")
      assert has_element?(view, "#skill-preview li", "Read the form.")

      view |> element("#skill-tab-write") |> render_click()
      refute has_element?(view, "#skill-preview")
    end
  end

  describe "editing a skill" do
    test "the page opens the skill with its version and origin", %{conn: conn, skill: skill} do
      {:ok, view, _html} = open(conn)
      assert field(view, "#skill-name") =~ ~s(value="pdf-forms")
      assert field(view, "#skill-description") =~ "Fill in PDF forms."
      assert field(view, "#skill-instructions") =~ "Read the form first."
      assert field(view, "#skill-version") =~ ~s(value="#{skill.version}")
      assert field(view, "#skill-meta") =~ "Version 1."
      assert has_element?(view, ~s(#skill-delete[data-confirm*="Blip and threads can't load it"]))
      refute has_element?(view, "#skill-install-notes")
    end

    test "an installed skill names its source and keeps its install notes", %{conn: conn} do
      {:ok, _skill} =
        Skills.install(
          %{
            "name" => "changelog",
            "description" => "Keep a changelog.",
            "instructions" => "Add."
          },
          %{
            origin: "fetched",
            source_url: "https://github.com/o/r/blob/main/changelog/SKILL.md",
            notes: ["Left out: scripts/bump.py.", "Ignored front matter: license."]
          }
        )

      {:ok, view, _html} = live(conn, ~p"/skills/changelog")
      assert field(view, "#skill-meta") =~ "Installed from"

      assert has_element?(
               view,
               "#skill-source[href='https://github.com/o/r/blob/main/changelog/SKILL.md']",
               "github.com/o/r/blob/main/changelog/SKILL.md"
             )

      assert has_element?(view, "#skill-installed-at[datetime]")
      assert has_element?(view, "#skill-install-notes li", "Left out: scripts/bump.py.")
      assert has_element?(view, "#skill-install-notes li", "Ignored front matter: license.")
    end

    test "saving bumps the version in the meta line", %{conn: conn, skill: skill} do
      {:ok, view, _html} = open(conn)

      type(view, %{instructions: "Read the form twice."})
      assert has_element?(view, ~s(#skill-form[data-dirty="true"]))

      html =
        view
        |> form("#skill-form", skill: %{instructions: "Read the form twice."})
        |> render_submit()

      assert html =~ "Saved pdf-forms."
      assert field(view, "#skill-meta") =~ "Version 2."
      assert field(view, "#skill-version") =~ ~s(value="2")
      assert has_element?(view, ~s(#skill-form[data-dirty="false"]))
      refute has_element?(view, "#skill-stale")
      assert %{version: 2, instructions: "Read the form twice."} = Skills.get(skill.id)
    end

    test "a rename that saves patches the URL to the new name", %{conn: conn, skill: skill} do
      {:ok, view, _html} = open(conn)

      view |> form("#skill-form", skill: %{name: "pdf-filler"}) |> render_submit()

      assert_patch(view, ~p"/skills/pdf-filler")
      assert field(view, "#skill-heading") =~ "pdf-filler"
      assert %{name: "pdf-filler", version: 2} = Skills.get(skill.id)
      assert page_title(view) =~ "pdf-filler"
    end

    test "a bad save shows the field's message and saves nothing", %{conn: conn, skill: skill} do
      {:ok, view, _html} = open(conn)

      html = view |> form("#skill-form", skill: %{description: " "}) |> render_submit()

      assert html =~ "Say when an agent should use this skill."
      assert %{version: 1, description: "Fill in PDF forms."} = Skills.get(skill.id)
    end

    test "a clean form loads a version saved elsewhere", %{conn: conn, skill: skill} do
      {:ok, view, _html} = open(conn)

      {:ok, _skill} = Skills.update(skill.id, %{"instructions" => "Saved elsewhere."}, 1)

      assert field(view, "#skill-instructions") =~ "Saved elsewhere."
      assert field(view, "#skill-meta") =~ "Version 2."
      refute has_element?(view, "#skill-stale")
    end

    test "a clean form follows a rename made elsewhere", %{conn: conn, skill: skill} do
      {:ok, view, _html} = open(conn)

      {:ok, _skill} = Skills.update(skill.id, %{"name" => "pdf-filler"}, 1)

      assert_patch(view, ~p"/skills/pdf-filler")
      assert field(view, "#skill-name") =~ ~s(value="pdf-filler")
    end

    test "a save against an older version shows the banner and keeps the text",
         %{conn: conn, skill: skill} do
      {:ok, view, _html} = open(conn)
      type(view, %{instructions: "My edit."})

      {:ok, _skill} = Skills.update(skill.id, %{"instructions" => "Saved elsewhere."}, 1)
      assert has_element?(view, "#skill-stale", "This skill changed since you opened it.")
      assert field(view, "#skill-instructions") =~ "My edit."

      view |> form("#skill-form", skill: %{instructions: "My edit."}) |> render_submit()
      assert has_element?(view, "#skill-stale")
      assert field(view, "#skill-instructions") =~ "My edit."
      assert %{version: 2, instructions: "Saved elsewhere."} = Skills.get(skill.id)

      # Keep my text: the next save writes over the saved version.
      view |> element("#skill-keep") |> render_click()
      refute has_element?(view, "#skill-stale")
      assert field(view, "#skill-version") =~ ~s(value="2")

      view |> form("#skill-form", skill: %{instructions: "My edit."}) |> render_submit()
      assert %{version: 3, instructions: "My edit."} = Skills.get(skill.id)
    end

    test "Load the saved version replaces the typed text", %{conn: conn, skill: skill} do
      {:ok, view, _html} = open(conn)
      type(view, %{instructions: "My edit."})

      {:ok, _skill} = Skills.update(skill.id, %{"instructions" => "Saved elsewhere."}, 1)
      view |> element("#skill-reload") |> render_click()

      refute has_element?(view, "#skill-stale")
      assert field(view, "#skill-instructions") =~ "Saved elsewhere."
      assert has_element?(view, ~s(#skill-form[data-dirty="false"]))
    end

    test "#skill-delete deletes it and returns to /skills", %{conn: conn, skill: skill} do
      {:ok, view, _html} = open(conn)

      {:ok, _view, html} =
        view
        |> element("#skill-delete")
        |> render_click()
        |> follow_redirect(conn, ~p"/skills")

      assert html =~ "Deleted pdf-forms."
      assert Skills.get(skill.id) == nil
    end

    test "a skill deleted elsewhere sends the page to /skills", %{conn: conn, skill: skill} do
      {:ok, view, _html} = open(conn)

      :ok = Skills.delete(skill.id)

      {path, flash} = assert_redirect(view)
      assert path == ~p"/skills"
      assert flash["error"] == "pdf-forms was deleted."
    end
  end

  describe "turning it on" do
    test "the switches turn it on and off for Blip and a project",
         %{conn: conn, skill: skill, garden: garden} do
      {:ok, view, _html} = open(conn)
      assert has_element?(view, ~s(#skill-scope-blip[aria-checked="false"]))
      assert has_element?(view, ~s(#skill-scope-#{garden.id}[aria-checked="false"]), "Garden")

      view |> element("#skill-scope-blip") |> render_click()
      assert has_element?(view, ~s(#skill-scope-blip[aria-checked="true"]))
      assert Skills.scopes(skill.id) == [:blip]

      view |> element("#skill-scope-#{garden.id}") |> render_click()
      assert has_element?(view, ~s(#skill-scope-#{garden.id}[aria-checked="true"]))
      assert Skills.scopes(skill.id) == [:blip, {:project, garden.id}]

      view |> element("#skill-scope-blip") |> render_click()
      view |> element("#skill-scope-#{garden.id}") |> render_click()
      assert has_element?(view, ~s(#skill-scope-blip[aria-checked="false"]))
      assert has_element?(view, ~s(#skill-scope-#{garden.id}[aria-checked="false"]))
      assert Skills.scopes(skill.id) == []
      assert field(view, "#skill-meta") =~ "Version 1."
    end

    test "a toggle while typing leaves the form and shows no banner", %{conn: conn} do
      {:ok, view, _html} = open(conn)
      type(view, %{instructions: "Half typed."})

      view |> element("#skill-scope-blip") |> render_click()

      assert has_element?(view, ~s(#skill-scope-blip[aria-checked="true"]))
      refute has_element?(view, "#skill-stale")
      assert field(view, "#skill-instructions") =~ "Half typed."
      assert has_element?(view, ~s(#skill-form[data-dirty="true"]))
    end

    test "a toggle made elsewhere shows on the page", %{conn: conn, skill: skill, garden: garden} do
      {:ok, view, _html} = open(conn)
      type(view, %{instructions: "Half typed."})

      :ok = Skills.enable(skill.id, {:project, garden.id})

      assert has_element?(view, ~s(#skill-scope-#{garden.id}[aria-checked="true"]))
      refute has_element?(view, "#skill-stale")
      assert field(view, "#skill-instructions") =~ "Half typed."
    end

    test "a refused enable shows why", %{conn: conn, skill: skill} do
      for n <- 1..30 do
        {:ok, other} =
          Skills.create(%{"name" => "skill-#{n}", "description" => "D.", "instructions" => "I."})

        :ok = Skills.enable(other.id, :blip)
      end

      {:ok, view, _html} = open(conn)
      html = view |> element("#skill-scope-blip") |> render_click()

      assert html =~ "30 skills are on here already."
      assert has_element?(view, ~s(#skill-scope-blip[aria-checked="false"]))
      assert Skills.scopes(skill.id) == []
    end

    test "a new project shows among the switches", %{conn: conn} do
      {:ok, view, _html} = open(conn)

      {:ok, house} = Projects.create(%{"name" => "House", "purpose" => "Keep the house."})

      assert has_element?(view, ~s(#skill-scope-#{house.id}[aria-checked="false"]), "House")
    end
  end

  describe "turning it on for a machine" do
    setup do
      for id <- ["mm1", "mp1"], do: {:ok, _key} = NodeKeys.issue(id)
      :ok
    end

    test "each known machine has a switch, and a removed one doesn't", %{conn: conn} do
      {:ok, _key} = NodeKeys.issue("old")
      :ok = NodeKeys.revoke("old")

      {:ok, view, _html} = open(conn)

      assert has_element?(
               view,
               ~s(#skill-machine-scopes[phx-update=stream] #skill-machine-row-mm1 #skill-scope-machine-mm1[aria-checked="false"]),
               "mm1"
             )

      assert has_element?(view, ~s(#skill-scope-machine-mp1[aria-checked="false"]), "mp1")
      refute has_element?(view, "#skill-machine-row-old")
      refute has_element?(view, "#skill-scope-machine-old")
      assert has_element?(view, "#skill-machines-hint")
    end

    test "with no machines, the group says so", %{conn: conn} do
      :ok = NodeKeys.revoke("mm1")
      :ok = NodeKeys.revoke("mp1")

      {:ok, view, _html} = open(conn)

      assert has_element?(view, "#skill-machine-scopes #skill-no-machines")
      refute has_element?(view, "#skill-machine-scopes [role=switch]")
    end

    test "the switch turns it on and off for that machine", %{conn: conn, skill: skill} do
      {:ok, view, _html} = open(conn)

      view |> element("#skill-scope-machine-mm1") |> render_click()
      assert has_element?(view, ~s(#skill-scope-machine-mm1[aria-checked="true"]))
      assert has_element?(view, ~s(#skill-scope-machine-mp1[aria-checked="false"]))
      assert Skills.scopes(skill.id) == [{:machine, "mm1"}]

      view |> element("#skill-scope-machine-mm1") |> render_click()
      assert has_element?(view, ~s(#skill-scope-machine-mm1[aria-checked="false"]))
      assert Skills.scopes(skill.id) == []
    end

    test "the 31st skill on a machine is refused with a flash", %{conn: conn, skill: skill} do
      for n <- 1..30 do
        {:ok, other} =
          Skills.create(%{"name" => "skill-#{n}", "description" => "D.", "instructions" => "I."})

        :ok = Skills.enable(other.id, {:machine, "mm1"})
      end

      {:ok, view, _html} = open(conn)
      html = view |> element("#skill-scope-machine-mm1") |> render_click()

      assert html =~ "30 skills are on here already."
      assert has_element?(view, ~s(#skill-scope-machine-mm1[aria-checked="false"]))
      assert Skills.scopes(skill.id) == []

      # Another machine still takes it.
      view |> element("#skill-scope-machine-mp1") |> render_click()
      assert Skills.scopes(skill.id) == [{:machine, "mp1"}]
    end

    test "a machine removed since the page loaded is refused with a flash",
         %{conn: conn, skill: skill} do
      {:ok, view, _html} = open(conn)

      # A stale page's click: the switch is still there, the machine isn't.
      html = render_click(view, "scope", %{"machine" => "gone", "on" => "true"})

      assert html =~ "There&#39;s no machine called gone."
      assert Skills.scopes(skill.id) == []
    end

    test "machines installed and removed while the page is open come and go", %{conn: conn} do
      {:ok, view, _html} = open(conn)
      assert has_element?(view, "#skill-machine-row-mm1")

      :ok = NodeKeys.revoke("mm1")
      refute has_element?(view, "#skill-machine-row-mm1")
      assert has_element?(view, "#skill-machine-row-mp1")

      {:ok, _key} = NodeKeys.issue("mm2")
      assert has_element?(view, ~s(#skill-machine-row-mm2 #skill-scope-machine-mm2), "mm2")
    end

    test "a machine reinstalled under its name keeps its switch on",
         %{conn: conn, skill: skill} do
      :ok = Skills.enable(skill.id, {:machine, "mm1"})
      {:ok, view, _html} = open(conn)

      :ok = NodeKeys.revoke("mm1")
      :ok = NodeKeys.forget("mm1")
      refute has_element?(view, "#skill-scope-machine-mm1")

      {:ok, _key} = NodeKeys.issue("mm1")
      assert has_element?(view, ~s(#skill-scope-machine-mm1[aria-checked="true"]))
    end

    test "a machine toggle made elsewhere shows on the page", %{conn: conn, skill: skill} do
      {:ok, view, _html} = open(conn)

      :ok = Skills.enable(skill.id, {:machine, "mp1"})

      assert has_element?(view, ~s(#skill-scope-machine-mp1[aria-checked="true"]))
      assert has_element?(view, ~s(#skill-scope-machine-mm1[aria-checked="false"]))
    end
  end
end
