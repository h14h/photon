defmodule Photon.SkillsTest do
  @moduledoc """
  `Photon.Skills` through its API, against the real database and Store.
  The rules themselves are covered in `test/core/skills/rules_test.exs`.
  """

  use Photon.DataCase, async: false

  alias Photon.{Projects, Skills}
  alias Photon.Skills.Skill

  # Writes go through the Store's commit line.
  @moduletag :durable

  defp skill!(name, overrides \\ %{}) do
    params =
      Map.merge(
        %{
          "name" => name,
          "description" => "Use for #{name}.",
          "instructions" => "# #{name}\n\nDo it."
        },
        overrides
      )

    {:ok, skill} = Skills.create(params)
    skill
  end

  defp project!(name) do
    {:ok, project} = Projects.create(%{"purpose" => "Work on #{name}.", "name" => name})
    project
  end

  defp names(skills), do: Enum.map(skills, & &1.name)

  describe "create/1" do
    test "makes a written skill at version 1, on nowhere, and announces it" do
      :ok = Skills.subscribe()

      assert {:ok, %Skill{id: "sk_" <> _ = id} = skill} =
               Skills.create(%{
                 name: " pdf-forms ",
                 description: " Fill in PDF forms. ",
                 instructions: "# PDF forms\n"
               })

      assert %Skill{
               name: "pdf-forms",
               description: "Fill in PDF forms.",
               instructions: "# PDF forms",
               version: 1,
               origin: "written",
               source_url: nil,
               install_notes: nil,
               files_left_out: []
             } = skill

      assert_receive {:skills_changed, ^id}
      assert Skills.get(id) == skill
      assert Skills.get_by_name("pdf-forms") == skill
      assert Skills.scopes(id) == []
    end

    test "a taken name or a bad field is refused, and nothing is made" do
      skill!("pdf-forms")
      :ok = Skills.subscribe()

      assert Skills.create(%{
               "name" => "pdf-forms",
               "description" => "Another.",
               "instructions" => "x"
             }) == {:error, %{name: "There's already a skill called pdf-forms."}}

      assert {:error, %{name: _, description: _}} =
               Skills.create(%{"name" => "PDF", "instructions" => "x"})

      assert names(Enum.map(Skills.list(), & &1.skill)) == ["pdf-forms"]
      refute_received {:skills_changed, _}
    end
  end

  describe "install/2" do
    test "keeps origin, source, notes and files left out from the candidate, not the form" do
      :ok = Skills.subscribe()

      candidate = %{
        path: "skills/pdf-forms",
        origin: "fetched",
        source_url: "https://github.com/o/r/blob/main/skills/pdf-forms/SKILL.md",
        name: "PDF Forms",
        description: "As found.",
        instructions: "As found.",
        notes: [
          "Left out: scripts/fill.py, reference.md. Photon skills are instructions only.",
          "Ignored front matter: license."
        ],
        files_left_out: ["scripts/fill.py", "reference.md"],
        error: nil
      }

      params = %{
        "name" => "pdf-forms",
        "description" => "Fill in PDF forms.",
        "instructions" => "Run scripts/fill.py.",
        "origin" => "written",
        "source_url" => "https://example.com/elsewhere"
      }

      assert {:ok, %Skill{id: id} = skill} = Skills.install(params, candidate)

      assert %Skill{
               name: "pdf-forms",
               description: "Fill in PDF forms.",
               instructions: "Run scripts/fill.py.",
               version: 1,
               origin: "fetched",
               source_url: "https://github.com/o/r/blob/main/skills/pdf-forms/SKILL.md",
               install_notes:
                 "Left out: scripts/fill.py, reference.md. Photon skills are instructions only.\n" <>
                   "Ignored front matter: license.",
               files_left_out: ["scripts/fill.py", "reference.md"]
             } = skill

      assert_receive {:skills_changed, ^id}
      assert Skills.get(id) == skill
      assert Skills.scopes(id) == []
    end

    test "a pasted skill with no notes keeps none" do
      params = %{"name" => "notes", "description" => "d", "instructions" => "i"}

      assert {:ok,
              %Skill{origin: "pasted", source_url: nil, install_notes: nil, files_left_out: []}} =
               Skills.install(params, %{origin: "pasted", notes: [], files_left_out: []})
    end

    test "a taken name is refused" do
      skill!("pdf-forms")
      params = %{"name" => "pdf-forms", "description" => "d", "instructions" => "i"}

      assert Skills.install(params, %{origin: "pasted"}) ==
               {:error, %{name: "There's already a skill called pdf-forms."}}
    end
  end

  describe "update/3" do
    test "saves at the loaded version, bumps it and announces" do
      skill = skill!("pdf-forms")
      id = skill.id
      :ok = Skills.subscribe()

      assert {:ok, %Skill{version: 2, description: "New.", instructions: "# pdf-forms\n\nDo it."}} =
               Skills.update(id, %{"description" => "New."}, 1)

      assert_receive {:skills_changed, ^id}
      assert %Skill{version: 2, description: "New."} = Skills.get(id)
    end

    test "an old version is stale and changes nothing" do
      skill = skill!("pdf-forms")
      {:ok, _} = Skills.update(skill.id, %{"description" => "Second."}, 1)
      :ok = Skills.subscribe()

      assert Skills.update(skill.id, %{"description" => "Third."}, 1) == {:error, :stale}
      assert %Skill{version: 2, description: "Second."} = Skills.get(skill.id)
      refute_received {:skills_changed, _}
    end

    test "renames, unless another skill has the name" do
      skill = skill!("pdf-forms")
      skill!("release-notes")

      assert {:ok, %Skill{name: "pdf-filler", version: 2}} =
               Skills.update(skill.id, %{"name" => "pdf-filler"}, 1)

      assert Skills.get_by_name("pdf-forms") == nil

      assert Skills.update(skill.id, %{"name" => "release-notes"}, 2) ==
               {:error, %{name: "There's already a skill called release-notes."}}

      assert {:error, %{name: _}} = Skills.update(skill.id, %{"name" => "new"}, 2)
      assert %Skill{name: "pdf-filler", version: 2} = Skills.get(skill.id)
    end

    test "a missing skill is :not_found" do
      assert Skills.update("sk_missing", %{"description" => "x"}, 1) == {:error, :not_found}
    end
  end

  describe "delete/1" do
    test "deletes the skill and its enablements, and announces" do
      skill = skill!("pdf-forms")
      garden = project!("Garden")
      :ok = Skills.enable(skill.id, :blip)
      :ok = Skills.enable(skill.id, {:project, garden.id})
      id = skill.id
      :ok = Skills.subscribe()

      assert Skills.delete(id) == :ok
      assert_receive {:skills_changed, ^id}
      assert Skills.get(id) == nil
      assert Skills.scopes(id) == []
      assert Skills.enabled(:blip) == []
      assert Skills.enabled({:project, garden.id}) == []

      assert Skills.delete(id) == {:error, :not_found}
    end
  end

  describe "enable/2 and disable/2" do
    test "turn a skill on and off for Blip and a project, and announce" do
      skill = skill!("pdf-forms")
      garden = project!("Garden")
      id = skill.id
      :ok = Skills.subscribe()

      assert Skills.enable(id, :blip) == :ok
      assert_receive {:skills_changed, ^id}
      assert Skills.enable(id, {:project, garden.id}) == :ok
      assert_receive {:skills_changed, ^id}
      assert Skills.scopes(id) == [:blip, {:project, garden.id}]

      assert Skills.disable(id, :blip) == :ok
      assert_receive {:skills_changed, ^id}
      assert Skills.scopes(id) == [{:project, garden.id}]

      assert Skills.disable(id, {:project, garden.id}) == :ok
      assert_receive {:skills_changed, ^id}
      assert Skills.scopes(id) == []
    end

    test "are idempotent, and a change that changes nothing announces nothing" do
      skill = skill!("pdf-forms")
      :ok = Skills.enable(skill.id, :blip)
      :ok = Skills.subscribe()

      assert Skills.enable(skill.id, :blip) == :ok
      assert Skills.scopes(skill.id) == [:blip]
      refute_received {:skills_changed, _}

      :ok = Skills.disable(skill.id, :blip)
      assert Skills.disable(skill.id, :blip) == :ok
      assert Skills.scopes(skill.id) == []
    end

    test "an unknown project or skill is refused" do
      skill = skill!("pdf-forms")

      assert Skills.enable(skill.id, {:project, "p_missing"}) ==
               {:error, "That project doesn't exist."}

      assert Skills.enable("sk_missing", :blip) == {:error, :not_found}
      assert Skills.scopes(skill.id) == []
    end

    test "a scope takes at most 30 skills" do
      garden = project!("Garden")

      skills = for n <- 1..31, do: skill!("skill-#{n}")

      {first_30, [last]} = Enum.split(skills, 30)
      for skill <- first_30, do: :ok = Skills.enable(skill.id, :blip)

      assert {:error, "30 skills are on here already." <> _} = Skills.enable(last.id, :blip)
      assert length(Skills.enabled(:blip)) == 30

      # Another scope has its own 30, and a skill already on is still :ok.
      assert Skills.enable(last.id, {:project, garden.id}) == :ok
      assert Skills.enable(hd(first_30).id, :blip) == :ok
    end
  end

  describe "reading" do
    test "enabled/1 is the scope's skills by name, and scopes don't mix" do
      garden = project!("Garden")
      house = project!("House")
      zeta = skill!("zeta")
      alpha = skill!("alpha")
      only_garden = skill!("garden-only")
      _off = skill!("off-everywhere")

      :ok = Skills.enable(zeta.id, :blip)
      :ok = Skills.enable(alpha.id, :blip)
      :ok = Skills.enable(only_garden.id, {:project, garden.id})
      :ok = Skills.enable(zeta.id, {:project, garden.id})

      assert names(Skills.enabled(:blip)) == ["alpha", "zeta"]
      assert names(Skills.enabled({:project, garden.id})) == ["garden-only", "zeta"]
      assert Skills.enabled({:project, house.id}) == []

      assert [%Skill{}, %Skill{instructions: "# zeta\n\nDo it."}] =
               Skills.enabled({:project, garden.id})
    end

    test "list/0 is every skill by name with its scopes, Blip first" do
      garden = project!("Garden")
      pdf = skill!("pdf-forms")
      notes = skill!("notes")

      :ok = Skills.enable(pdf.id, {:project, garden.id})
      :ok = Skills.enable(pdf.id, :blip)

      assert [
               %{id: notes_id, skill: %Skill{name: "notes"}, scopes: []},
               %{id: pdf_id, skill: %Skill{name: "pdf-forms"}, scopes: pdf_scopes}
             ] = Skills.list()

      assert notes_id == notes.id
      assert pdf_id == pdf.id
      assert pdf_scopes == [:blip, {:project, garden.id}]
      assert Skills.scopes(pdf.id) == pdf_scopes
    end
  end
end
