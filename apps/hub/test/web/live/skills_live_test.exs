defmodule PhotonWeb.SkillsLiveTest do
  @moduledoc """
  The Skills page: the empty state, each skill's row (where it is on and
  how it arrived), the Blip switch, and changes made elsewhere.

  Writes from the test process are other processes' writes as far as the
  page is concerned. The Store broadcasts inside the commit's call, so
  the page has the announcement queued before the test's next render.
  """

  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Photon.{Projects, Skills}

  @moduletag :durable

  defp skill!(name, description \\ "Use it when the task calls for it.") do
    {:ok, skill} =
      Skills.create(%{"name" => name, "description" => description, "instructions" => "Do it."})

    skill
  end

  defp project!(name) do
    {:ok, project} = Projects.create(%{"name" => name, "purpose" => "Look after the #{name}."})
    project
  end

  defp text(view, selector), do: view |> element(selector) |> render() |> strip()

  defp strip(html),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  test "with no skills, the page says how to add one", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/skills")
    assert has_element?(view, "#skills #no-skills")
    refute has_element?(view, "#skills article")
    assert has_element?(view, "#new-skill[href='/skills/new']")
    assert has_element?(view, "#install-skill[href='/skills/install']")
  end

  test "each skill says where it is on and how it arrived", %{conn: conn} do
    garden = project!("Garden")
    house = project!("House")
    pdf = skill!("pdf-forms", "Fill in PDF forms.")
    notes = skill!("release-notes")

    {:ok, fetched} =
      Skills.install(
        %{"name" => "changelog", "description" => "Keep a changelog.", "instructions" => "Add."},
        %{origin: "fetched", source_url: "https://github.com/o/r/blob/main/changelog/SKILL.md"}
      )

    {:ok, pasted} =
      Skills.install(
        %{"name" => "haiku", "description" => "Write haiku.", "instructions" => "5, 7, 5."},
        %{origin: "pasted"}
      )

    :ok = Skills.enable(pdf.id, {:project, garden.id})
    :ok = Skills.enable(pdf.id, :blip)
    :ok = Skills.enable(pdf.id, {:project, house.id})
    :ok = Skills.enable(fetched.id, {:project, house.id})

    {:ok, view, _html} = live(conn, ~p"/skills")

    assert has_element?(view, "#skill-#{pdf.id} a[href='/skills/pdf-forms']", "pdf-forms")
    assert text(view, "#skill-#{pdf.id}") =~ "Fill in PDF forms."
    assert text(view, "#skill-#{pdf.id}-scopes") == "On for Blip, Garden and House"
    assert text(view, "#skill-#{pdf.id}-origin") == "Written here"
    assert has_element?(view, ~s(#skill-#{pdf.id}-blip[aria-checked="true"]))

    assert text(view, "#skill-#{notes.id}-scopes") == "Off everywhere"
    assert has_element?(view, ~s(#skill-#{notes.id}-blip[aria-checked="false"]))

    assert text(view, "#skill-#{fetched.id}-scopes") == "On for House"

    assert text(view, "#skill-#{fetched.id}-origin") ==
             "From github.com/o/r/blob/main/changelog/SKILL.md"

    assert text(view, "#skill-#{pasted.id}-origin") == "Pasted"
  end

  test "a skill on for a machine names the machine", %{conn: conn} do
    {:ok, _key} = Photon.NodeKeys.issue("mm1")
    garden = project!("Garden")
    ios = skill!("ios-simulators")
    :ok = Skills.enable(ios.id, {:machine, "mm1"})

    {:ok, view, _html} = live(conn, ~p"/skills")
    assert text(view, "#skill-#{ios.id}-scopes") == "On for machine mm1"

    :ok = Skills.enable(ios.id, :blip)
    :ok = Skills.enable(ios.id, {:project, garden.id})
    assert text(view, "#skill-#{ios.id}-scopes") == "On for Blip, machine mm1 and Garden"
  end

  test "a removed machine drops out of the line", %{conn: conn} do
    {:ok, _key} = Photon.NodeKeys.issue("mm1")
    ios = skill!("ios-simulators")
    :ok = Skills.enable(ios.id, {:machine, "mm1"})

    {:ok, view, _html} = live(conn, ~p"/skills")
    assert text(view, "#skill-#{ios.id}-scopes") == "On for machine mm1"

    :ok = Photon.NodeKeys.revoke("mm1")
    assert text(view, "#skill-#{ios.id}-scopes") == "Off everywhere"
  end

  test "the Blip switch turns a skill on and off for Blip", %{conn: conn} do
    skill = skill!("pdf-forms")
    {:ok, view, _html} = live(conn, ~p"/skills")

    view |> element("#skill-#{skill.id}-blip") |> render_click()
    assert Skills.scopes(skill.id) == [:blip]
    assert has_element?(view, ~s(#skill-#{skill.id}-blip[aria-checked="true"]))
    assert text(view, "#skill-#{skill.id}-scopes") == "On for Blip"

    view |> element("#skill-#{skill.id}-blip") |> render_click()
    assert Skills.scopes(skill.id) == []
    assert has_element?(view, ~s(#skill-#{skill.id}-blip[aria-checked="false"]))
    assert text(view, "#skill-#{skill.id}-scopes") == "Off everywhere"
  end

  test "a refused enable shows why", %{conn: conn} do
    for n <- 1..30, do: :ok = Skills.enable(skill!("skill-#{n}").id, :blip)
    extra = skill!("one-more")
    {:ok, view, _html} = live(conn, ~p"/skills")

    html = view |> element("#skill-#{extra.id}-blip") |> render_click()

    assert html =~ "30 skills are on here already."
    assert Skills.scopes(extra.id) == []
    assert has_element?(view, ~s(#skill-#{extra.id}-blip[aria-checked="false"]))
  end

  test "changes made elsewhere show on the open page", %{conn: conn} do
    garden = project!("Garden")
    {:ok, view, _html} = live(conn, ~p"/skills")
    assert has_element?(view, "#no-skills")

    skill = skill!("pdf-forms")
    assert has_element?(view, "#skill-#{skill.id}", "pdf-forms")

    :ok = Skills.enable(skill.id, {:project, garden.id})
    assert text(view, "#skill-#{skill.id}-scopes") == "On for Garden"

    {:ok, _garden} = Projects.update(garden.id, %{"name" => "Yard"})
    assert text(view, "#skill-#{skill.id}-scopes") == "On for Yard"

    :ok = Skills.delete(skill.id)
    refute has_element?(view, "#skill-#{skill.id}")
  end
end
