defmodule PhotonWeb.SkillInstallLiveTest do
  @moduledoc """
  The install page: reading a pasted SKILL.md, fetching a link (against
  the `Req.Test` stub `config/test.exs` points `Photon.Skills` at),
  picking from a folder of skills, and the messages for what can't be
  installed. The rules for links and notes are covered in
  `test/core/skills/source_test.exs` and the requests in
  `test/boundary/skills_fetch_test.exs`; these check what the page shows
  and installs.

  The stub belongs to the test process; the page's fetch task finds it
  through `$callers` (the test, then the LiveView).
  """

  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Photon.Skills
  alias Photon.Skills.Skill

  @moduletag :durable

  @pdf_forms """
  ---
  name: pdf-forms
  description: Fill in PDF forms. Use when the user asks to fill or flatten a PDF form.
  license: Apache-2.0
  ---

  # PDF forms

  Run `scripts/fill.py` with the form.
  """

  # The trees of the folders the tests link to (`Photon.Skills.Source.tree_url/1`).
  @tree_skills "api.github.com/repos/o/r/git/trees/main:skills"
  @tree_pdf "api.github.com/repos/o/r/git/trees/main:skills/pdf-forms"
  @raw_main "raw.githubusercontent.com/o/r/main/"
  @blob "https://github.com/o/r/blob/main/skills/pdf-forms/SKILL.md"

  defp skill_md(name),
    do: "---\nname: #{name}\ndescription: Use for #{name}.\n---\n\nDo #{name}.\n"

  defp tree(files) do
    %{
      "sha" => "abc",
      "tree" => Enum.map(files, &%{"path" => &1, "type" => "blob", "mode" => "100644"}),
      "truncated" => false
    }
  end

  # Answers each request with `answers`' function for "host/path"; a
  # missing one is a 404.
  defp stub(answers) do
    Req.Test.stub(Skills, fn conn ->
      case Map.fetch(answers, conn.host <> conn.request_path) do
        {:ok, answer} -> answer.(conn)
        :error -> Plug.Conn.send_resp(conn, 404, "Not Found")
      end
    end)
  end

  defp json(value), do: &Req.Test.json(&1, value)
  defp text(value), do: &Req.Test.text(&1, value)

  defp open(conn) do
    {:ok, view, _html} = live(conn, ~p"/skills/install")
    view
  end

  defp fetch(view, url) do
    _html = view |> form("#install-url-form", link: %{url: url}) |> render_submit()
    render_async(view)
  end

  defp paste(view, text) do
    _html = view |> element("#install-tab-paste") |> render_click()
    view |> form("#install-paste-form", paste: %{text: text}) |> render_submit()
  end

  defp field(view, selector), do: view |> element(selector) |> render()

  describe "the page" do
    test "opens on the link tab, with the paste form hidden", %{conn: conn} do
      view = open(conn)

      assert has_element?(view, ~s(#install-tab-url[aria-selected="true"]))
      assert has_element?(view, "#install-url-form #install-url")
      assert has_element?(view, "#install-paste-form.hidden")
      refute has_element?(view, "#install-form")
      refute has_element?(view, "#install-candidates")

      _html = view |> element("#install-tab-paste") |> render_click()
      assert has_element?(view, ~s(#install-tab-paste[aria-selected="true"]))
      assert has_element?(view, "#install-url-form.hidden")
      refute has_element?(view, "#install-paste-form.hidden")
    end
  end

  describe "pasting a SKILL.md" do
    test "fills the preview, shows its notes, and installs it off everywhere", %{conn: conn} do
      view = open(conn)
      _html = paste(view, @pdf_forms)

      assert has_element?(view, "#install-form")
      assert field(view, "#install-name") =~ ~s(value="pdf-forms")
      assert field(view, "#install-description") =~ "Fill in PDF forms."
      assert field(view, "#install-instructions") =~ "Run `scripts/fill.py` with the form."
      assert has_element?(view, "#install-source", "From a pasted SKILL.md")
      assert has_element?(view, "#install-notes li", "Ignored front matter: license.")

      assert has_element?(
               view,
               "#install-notes li",
               "The instructions mention scripts/fill.py, which wasn't installed."
             )

      # The preview tab renders the instructions.
      _html = view |> element("#install-tab-preview") |> render_click()
      assert has_element?(view, "#install-instructions-preview h1", "PDF forms")

      {:ok, _view, html} =
        view
        |> form("#install-form")
        |> render_submit()
        |> follow_redirect(conn, ~p"/skills/pdf-forms")

      assert html =~ "Installed pdf-forms. It&#39;s off everywhere; turn it on below."

      assert %Skill{origin: "pasted", source_url: nil} = skill = Skills.get_by_name("pdf-forms")
      assert skill.install_notes =~ "Ignored front matter: license."
      assert skill.files_left_out == ["scripts/fill.py"]
      assert Skills.scopes(skill.id) == []
    end

    test "installs under the name typed in the preview", %{conn: conn} do
      view = open(conn)
      _html = paste(view, @pdf_forms)

      {:ok, _view, _html} =
        view
        |> form("#install-form", install: %{name: "pdf-filler"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/skills/pdf-filler")

      assert %Skill{description: "Fill in PDF forms." <> _} = Skills.get_by_name("pdf-filler")
      refute Skills.get_by_name("pdf-forms")
    end

    test "shows a format example in the empty paste field, on several lines", %{conn: conn} do
      view = open(conn)
      textarea = field(view, "#install-paste")

      assert textarea =~ "placeholder=\"---\nname: pdf-forms\ndescription:"
      refute textarea =~ "\\n"
    end

    test "flags a missing description under its field as soon as the preview opens", %{
      conn: conn
    } do
      view = open(conn)
      _html = paste(view, "---\nname: notes\n---\n\nWrite notes.\n")

      assert has_element?(view, "#install-form", "Say when an agent should use this skill.")
      assert field(view, "#install-name") =~ ~s(value="notes")

      # The message stays while it is empty, and goes once it is filled in.
      _html = view |> form("#install-form", install: %{name: "notes-2"}) |> render_change()
      assert has_element?(view, "#install-form", "Say when an agent should use this skill.")

      _html = view |> form("#install-form", install: %{description: "Use it."}) |> render_change()
      refute has_element?(view, "#install-form", "Say when an agent should use this skill.")
    end

    test "a read while a fetch runs cancels the fetch, so the paste stays", %{conn: conn} do
      test = self()

      Req.Test.stub(Skills, fn conn ->
        send(test, {:waiting, self()})

        receive do
          :go -> Plug.Conn.send_resp(conn, 404, "Not Found")
        end
      end)

      view = open(conn)
      _html = view |> form("#install-url-form", link: %{url: @blob}) |> render_submit()
      assert_receive {:waiting, stub}
      ref = Process.monitor(stub)

      _html = paste(view, @pdf_forms)
      assert_receive {:DOWN, ^ref, :process, ^stub, _reason}
      _html = render_async(view)

      refute has_element?(view, "#install-fetching")
      refute has_element?(view, "#install-fetch[disabled]")
      assert field(view, "#install-name") =~ ~s(value="pdf-forms")
      refute has_element?(view, "#install-error")
    end

    test "that can't be read shows why under the field", %{conn: conn} do
      view = open(conn)
      _html = paste(view, "# Just notes")

      assert has_element?(view, "#install-paste-form #install-error", "starts with front matter")
      refute has_element?(view, "#install-form")
    end

    test "with a name that's taken says so under the field, and refuses", %{conn: conn} do
      {:ok, _skill} =
        Skills.create(%{
          "name" => "pdf-forms",
          "description" => "Mine.",
          "instructions" => "Mine."
        })

      view = open(conn)
      _html = paste(view, @pdf_forms)
      assert field(view, "#install-form") =~ "There&#39;s already a skill called pdf-forms."

      _html = view |> form("#install-form") |> render_submit()
      assert field(view, "#install-form") =~ "There&#39;s already a skill called pdf-forms."
      assert %Skill{description: "Mine."} = Skills.get_by_name("pdf-forms")

      # A free name clears the message as it is typed.
      _html = view |> form("#install-form", install: %{name: "pdf-forms-2"}) |> render_change()
      refute field(view, "#install-form") =~ "There&#39;s already a skill"
    end
  end

  describe "fetching a link" do
    test "shows Fetching... until the answer comes", %{conn: conn} do
      test = self()

      Req.Test.stub(Skills, fn conn ->
        send(test, {:waiting, self()})

        receive do
          :go -> Plug.Conn.send_resp(conn, 404, "Not Found")
        end
      end)

      view = open(conn)
      _html = view |> form("#install-url-form", link: %{url: @blob}) |> render_submit()

      assert_receive {:waiting, stub}
      assert has_element?(view, "#install-fetching", "Fetching...")
      assert has_element?(view, "#install-fetch[disabled]")

      send(stub, :go)
      # The tree call failed, so the file is downloaded on its own.
      assert_receive {:waiting, stub}
      send(stub, :go)

      _html = render_async(view)
      refute has_element?(view, "#install-fetching")
      assert has_element?(view, "#install-error", "GitHub says there")
    end

    test "a link to a SKILL.md previews it and installs it with its notes", %{conn: conn} do
      stub(%{
        @tree_pdf => json(tree(["SKILL.md", "scripts/fill.py", "reference.md"])),
        (@raw_main <> "skills/pdf-forms/SKILL.md") => text(@pdf_forms)
      })

      view = open(conn)
      _html = fetch(view, @blob)

      assert field(view, "#install-name") =~ ~s(value="pdf-forms")

      assert has_element?(
               view,
               "#install-source a[href='#{@blob}']",
               "github.com/o/r/blob/main/skills/pdf-forms/SKILL.md"
             )

      assert has_element?(
               view,
               "#install-notes li",
               "Left out: reference.md, scripts/fill.py. Photon skills are instructions only."
             )

      {:ok, _view, _html} =
        view
        |> form("#install-form")
        |> render_submit()
        |> follow_redirect(conn, ~p"/skills/pdf-forms")

      skill = Skills.get_by_name("pdf-forms")
      assert %Skill{origin: "fetched", source_url: @blob} = skill

      assert skill.install_notes ==
               Enum.join(
                 [
                   "Left out: reference.md, scripts/fill.py. Photon skills are instructions only.",
                   "Ignored front matter: license.",
                   "The instructions mention scripts/fill.py, which wasn't installed."
                 ],
                 "\n"
               )

      assert skill.files_left_out == ["scripts/fill.py", "reference.md"]
    end

    test "a 404 shows the message under the field", %{conn: conn} do
      stub(%{})

      view = open(conn)
      _html = fetch(view, "https://example.com/skills/SKILL.md")

      assert has_element?(
               view,
               "#install-url-form #install-error",
               "Nothing at that address (404)."
             )

      refute has_element?(view, "#install-form")
    end

    test "a link's error stays with the link, not under the paste field", %{conn: conn} do
      stub(%{})
      view = open(conn)
      _html = fetch(view, "https://github.com/o/r/tree/main/skills")
      assert has_element?(view, "#install-url-form #install-error", "GitHub says there")

      _html = view |> element("#install-tab-paste") |> render_click()
      refute has_element?(view, "#install-error")

      _html = view |> element("#install-tab-url") |> render_click()
      assert has_element?(view, "#install-url-form #install-error", "GitHub says there")
    end

    test "a link that isn't one shows the message under the field", %{conn: conn} do
      view = open(conn)
      _html = fetch(view, "ftp://example.com/SKILL.md")

      assert has_element?(view, "#install-error", "Give an https:// link")
    end
  end

  describe "a folder of skills" do
    setup do
      {:ok, taken} =
        Skills.create(%{
          "name" => "skill-b",
          "description" => "Already here.",
          "instructions" => "Mine."
        })

      stub(%{
        @tree_skills =>
          json(
            tree([
              "a/SKILL.md",
              "b/SKILL.md",
              "c/SKILL.md",
              "d/SKILL.md",
              "e/SKILL.md",
              "f/SKILL.md"
            ])
          ),
        (@raw_main <> "skills/a/SKILL.md") => text(skill_md("skill-a")),
        (@raw_main <> "skills/b/SKILL.md") => text(skill_md("skill-b")),
        (@raw_main <> "skills/c/SKILL.md") => text(skill_md("skill-c")),
        # skills/d/SKILL.md is missing: its download fails.
        (@raw_main <> "skills/e/SKILL.md") =>
          text("---\nname: skill-e\n---\n\nNo description above.\n"),
        (@raw_main <> "skills/f/SKILL.md") =>
          text(
            "---\nname: skill-f\ndescription: Too long.\n---\n\n" <>
              String.duplicate("x", 50_001)
          )
      })

      %{taken: taken}
    end

    test "lists each one, and installs the picked ones", %{conn: conn} do
      view = open(conn)
      _html = fetch(view, "https://github.com/o/r/tree/main/skills")

      for n <- 0..5, do: assert(has_element?(view, "#install-candidates #install-candidate-#{n}"))
      assert has_element?(view, "#install-candidate-0", "skill-a")
      assert has_element?(view, "#install-candidate-0", "Use for skill-a.")
      refute has_element?(view, "#install-notice")
      assert has_element?(view, "#install-selected[disabled]")

      _html = view |> form("#install-pick-form", picked: ["0", "2"]) |> render_change()
      assert has_element?(view, "#install-picked", "2 picked.")
      refute has_element?(view, "#install-selected[disabled]")

      {:ok, _view, html} =
        view
        |> form("#install-pick-form", picked: ["0", "2"])
        |> render_submit()
        |> follow_redirect(conn, ~p"/skills")

      assert html =~ "Installed 2 skills. They&#39;re off everywhere until you turn them on."

      for name <- ["skill-a", "skill-c"] do
        assert %Skill{origin: "fetched", id: id} = Skills.get_by_name(name)
        assert Skills.scopes(id) == []
      end

      assert %Skill{source_url: "https://github.com/o/r/blob/main/skills/a/SKILL.md"} =
               Skills.get_by_name("skill-a")
    end

    test "can't pick a taken name, a failed download or a SKILL.md without a description",
         %{conn: conn} do
      view = open(conn)
      _html = fetch(view, "https://github.com/o/r/tree/main/skills")

      assert has_element?(view, "#install-candidate-1-pick[disabled]")

      assert has_element?(
               view,
               "#install-candidate-1-reason",
               "There's already a skill called skill-b."
             )

      assert has_element?(view, "#install-candidate-3-pick[disabled]")
      assert has_element?(view, "#install-candidate-3", "d")
      assert has_element?(view, "#install-candidate-3-reason", "GitHub says there")
      refute has_element?(view, "#install-candidate-3-alone")

      assert has_element?(view, "#install-candidate-4-pick[disabled]")
      assert has_element?(view, "#install-candidate-4-reason", "no description")

      refute has_element?(view, "#install-candidate-0-pick[disabled]")
    end

    test "a name taken elsewhere while the list is open can't be picked", %{conn: conn} do
      view = open(conn)
      _html = fetch(view, "https://github.com/o/r/tree/main/skills")
      refute has_element?(view, "#install-candidate-2-pick[disabled]")

      {:ok, _skill} =
        Skills.create(%{"name" => "skill-c", "description" => "Mine.", "instructions" => "Mine."})

      assert has_element?(view, "#install-candidate-2-pick[disabled]")
      assert has_element?(view, "#install-candidate-2-reason", "already a skill called skill-c")
    end

    test "a pick that fails stays listed with its message", %{conn: conn} do
      view = open(conn)
      _html = fetch(view, "https://github.com/o/r/tree/main/skills")

      html = view |> form("#install-pick-form", picked: ["0", "5"]) |> render_submit()
      assert html =~ "1 skill couldn&#39;t be installed; see why below."
      assert html =~ "Installed 1 skill. It&#39;s off everywhere until you turn it on."

      assert has_element?(view, "#install-candidate-0-installed", "skill-a")
      assert has_element?(view, "#install-candidate-5-pick[disabled]")
      assert has_element?(view, "#install-candidate-5-reason", "50,000")
      assert Skills.get_by_name("skill-a")
      refute Skills.get_by_name("skill-f")
    end

    test "one that can't be picked installs on its own, with a way back", %{conn: conn} do
      view = open(conn)
      _html = fetch(view, "https://github.com/o/r/tree/main/skills")

      _html = view |> element("#install-candidate-4-alone") |> render_click()
      assert field(view, "#install-name") =~ ~s(value="skill-e")
      assert has_element?(view, "#install-source", "github.com/o/r/blob/main/skills/e/SKILL.md")

      _html = view |> element("#install-back-to-list") |> render_click()
      assert has_element?(view, "#install-candidate-4-reason", "no description")

      _html = view |> form("#install-pick-form", picked: ["0"]) |> render_change()
      _html = view |> element("#install-candidate-4-alone") |> render_click()

      html =
        view
        |> form("#install-form", install: %{description: "Use for e."})
        |> render_submit()

      # Back on the list, with that row installed and the pick kept.
      assert html =~ "Installed skill-e. It&#39;s off everywhere until you turn it on."
      refute has_element?(view, "#install-form")
      assert has_element?(view, "#install-candidate-4-installed", "skill-e")
      assert has_element?(view, "#install-picked", "1 picked.")
      assert has_element?(view, "#install-candidate-1-reason", "already a skill called skill-b")

      assert %Skill{
               description: "Use for e.",
               source_url: "https://github.com/o/r/blob/main/skills/e/SKILL.md"
             } = Skills.get_by_name("skill-e")
    end
  end

  test "a folder of more than 30 shows the notice above the first 30", %{conn: conn} do
    folders = for n <- 1..31, do: "skills/s#{String.pad_leading("#{n}", 2, "0")}"

    answers =
      Map.new(folders, fn folder ->
        {@raw_main <> folder <> "/SKILL.md", text(skill_md(String.replace(folder, "/", "-")))}
      end)

    listed = Enum.map(folders, &String.replace_prefix(&1 <> "/SKILL.md", "skills/", ""))
    stub(Map.put(answers, @tree_skills, json(tree(listed))))

    view = open(conn)
    _html = fetch(view, "https://github.com/o/r/tree/main/skills")

    assert has_element?(
             view,
             "#install-notice",
             "This folder has 31 skills; showing the first 30."
           )

    assert has_element?(view, "#install-candidate-29")
    refute has_element?(view, "#install-candidate-30")
  end
end
