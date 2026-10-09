defmodule Photon.SkillsTest do
  @moduledoc """
  `Photon.Skills` through its API, against the real database and Store.
  The rules themselves are covered in `test/core/skills/rules_test.exs`.
  """

  use Photon.DataCase, async: false

  alias Photon.Durable.Tx
  alias Photon.{NodeKeys, Projects, Repo, Skills}
  alias Photon.Skills.{Enablement, Prompt, Skill}

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

  describe "read/1" do
    test "a pasted SKILL.md is a candidate install keeps, with its notes" do
      text = """
      ---
      name: PDF Forms
      description: Fill in PDF forms.
      license: Apache-2.0
      ---

      # PDF forms

      Run `scripts/fill.py` with the form.
      """

      assert {:ok, candidate} = Skills.read(text)

      assert candidate == %{
               origin: "pasted",
               path: "",
               source_url: nil,
               name: "pdf-forms",
               description: "Fill in PDF forms.",
               instructions: "# PDF forms\n\nRun `scripts/fill.py` with the form.",
               notes: [
                 "Ignored front matter: license.",
                 "The instructions mention scripts/fill.py, which wasn't installed.",
                 ~s(Renamed from "PDF Forms" to pdf-forms: names use lowercase letters, ) <>
                   "digits and hyphens."
               ],
               files_left_out: ["scripts/fill.py"],
               error: nil,
               found: %{name: "PDF Forms", ignored: ["license"], files: [], notes: []}
             }

      params = Map.take(candidate, [:name, :description, :instructions])
      assert {:ok, %Skill{} = skill} = Skills.install(params, candidate)

      assert %Skill{origin: "pasted", files_left_out: ["scripts/fill.py"]} = skill
      assert skill.install_notes == Enum.join(candidate.notes, "\n")
    end

    test "notes made for the SKILL.md follow what the owner changed in the preview" do
      {:ok, candidate} =
        Skills.read("""
        ---
        name: PDF Forms
        description: Fill in PDF forms.
        ---

        Run `scripts/fill.py` with the form.
        """)

      params = %{
        "name" => "pdf-filler",
        "description" => "Fill in PDF forms.",
        "instructions" => "Fill the form by hand."
      }

      assert {:ok, %Skill{install_notes: notes, files_left_out: []}} =
               Skills.install(params, candidate)

      assert notes == ~s(Renamed from "PDF Forms" to pdf-filler.)
    end

    test "text that isn't a SKILL.md is refused with the parser's message" do
      assert Skills.read("# Just notes") ==
               {:error,
                "A SKILL.md starts with front matter: a line with three dashes (---), " <>
                  "then name: and description: lines, then another ---."}

      assert Skills.read("---\nname: x\ndescription: y\n---\n\n") ==
               {:error, "This SKILL.md has no instructions after its front matter."}
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

  describe "enable_tx/3 and disable_tx/3" do
    test "change a scope inside the caller's commit, and announce once it's stored" do
      pdf = skill!("pdf-forms")
      notes = skill!("release-notes")
      garden = project!("Garden")
      scope = {:project, garden.id}
      :ok = Skills.subscribe()

      assert Durable.commit(fn tx ->
               :ok = Skills.enable_tx(tx, pdf.id, scope)
               :ok = Skills.enable_tx(tx, notes.id, scope)
               Skills.disable_tx(tx, notes.id, scope)
             end) == :ok

      assert names(Skills.enabled(scope)) == ["pdf-forms"]
      pdf_id = pdf.id
      assert_receive {:skills_changed, ^pdf_id}

      # A commit that rolls back keeps none of it, and announces nothing.
      flush_skills()

      assert {:rolled_back, :no} =
               Durable.commit(fn tx ->
                 :ok = Skills.disable_tx(tx, pdf.id, scope)
                 :ok = Skills.enable_tx(tx, notes.id, scope)
                 Tx.rollback(:no)
               end)

      assert names(Skills.enabled(scope)) == ["pdf-forms"]
      refute_received {:skills_changed, _}
    end

    test "refuse as enable/2 does, and change nothing" do
      pdf = skill!("pdf-forms")

      assert Durable.commit(&Skills.enable_tx(&1, pdf.id, {:project, "p_missing"})) ==
               {:error, "That project doesn't exist."}

      assert Durable.commit(&Skills.enable_tx(&1, "sk_missing", :blip)) == {:error, :not_found}
      assert Durable.commit(&Skills.disable_tx(&1, pdf.id, :blip)) == :ok
      assert Skills.scopes(pdf.id) == []
    end
  end

  defp flush_skills do
    receive do
      {:skills_changed, _id} -> flush_skills()
    after
      0 -> :ok
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

  describe "machine scopes" do
    defp machine!(id) do
      {:ok, _key} = NodeKeys.issue(id)
      id
    end

    defp local_node! do
      Photon.TestConfig.put_env(:photon, :local_node, true)
    end

    defp load(scope, name), do: Durable.commit(&Skills.load_tx(&1, scope, name))

    test "turn a skill on and off for a machine, and announce" do
      skill = skill!("ios-simulators")
      machine!("mm1")
      id = skill.id
      :ok = Skills.subscribe()

      assert Skills.enable(id, {:machine, "mm1"}) == :ok
      assert_receive {:skills_changed, ^id}
      assert Skills.scopes(id) == [{:machine, "mm1"}]
      assert names(Skills.enabled({:machine, "mm1"})) == ["ios-simulators"]

      # On already, or off already: nothing changes and nothing is announced.
      assert Skills.enable(id, {:machine, "mm1"}) == :ok
      refute_received {:skills_changed, _}

      assert Skills.disable(id, {:machine, "mm1"}) == :ok
      assert_receive {:skills_changed, ^id}
      assert Skills.scopes(id) == []

      assert Skills.disable(id, {:machine, "mm1"}) == :ok
      refute_received {:skills_changed, _}
    end

    test "a machine the hub doesn't know is refused" do
      skill = skill!("ios-simulators")

      assert Skills.enable(skill.id, {:machine, "mm9"}) ==
               {:error, "There's no machine called mm9."}

      assert Durable.commit(&Skills.enable_tx(&1, skill.id, {:machine, "mm9"})) ==
               {:error, "There's no machine called mm9."}

      assert Skills.scopes(skill.id) == []
    end

    test "each machine takes at most 30 skills, apart from Blip and other machines" do
      machine!("mm1")
      machine!("mp1")
      skills = for n <- 1..31, do: skill!("skill-#{n}")
      {first_30, [last]} = Enum.split(skills, 30)
      for skill <- first_30, do: :ok = Skills.enable(skill.id, {:machine, "mm1"})

      assert {:error, "30 skills are on here already." <> _} =
               Skills.enable(last.id, {:machine, "mm1"})

      assert length(Skills.enabled({:machine, "mm1"})) == 30
      assert Skills.enable(last.id, {:machine, "mp1"}) == :ok
      assert Skills.enable(last.id, :blip) == :ok
    end

    test "machine_skills/0 groups them by machine, local first, apart from the agent's own" do
      local_node!()
      machine!("mp1")
      machine!("mm1")
      machine!("nas")
      garden = project!("Garden")
      ios = skill!("ios-simulators")
      xcode = skill!("xcode")
      hosting = skill!("hosting-private-apps")
      pdf = skill!("pdf-forms")

      :ok = Skills.enable(xcode.id, {:machine, "mm1"})
      :ok = Skills.enable(hosting.id, {:machine, "mp1"})
      :ok = Skills.enable(ios.id, {:machine, "mm1"})
      :ok = Skills.enable(hosting.id, {:machine, "local"})
      :ok = Skills.enable(pdf.id, :blip)

      machines = Skills.machine_skills()

      assert Enum.map(machines, fn {id, skills} -> {id, names(skills)} end) == [
               {"local", ["hosting-private-apps"]},
               {"mm1", ["ios-simulators", "xcode"]},
               {"mp1", ["hosting-private-apps"]}
             ]

      assert [{"local", [%Skill{instructions: "# hosting-private-apps\n\nDo it."}]} | _] =
               machines

      assert %{own: [%Skill{name: "pdf-forms"}], machines: ^machines} = Skills.offered(:blip)

      # A project with no skills of its own is still offered the machines'.
      assert Skills.offered({:project, garden.id}) == %{own: [], machines: machines}
    end

    test "a removed machine's skills are hidden until it is installed again" do
      machine!("mm1")
      machine!("mp1")
      ios = skill!("ios-simulators")
      hosting = skill!("hosting-private-apps")
      xcode = skill!("xcode")
      :ok = Skills.enable(ios.id, {:machine, "mm1"})
      :ok = Skills.enable(ios.id, :blip)
      :ok = Skills.enable(hosting.id, {:machine, "mm1"})
      :ok = Skills.enable(hosting.id, {:machine, "mp1"})

      :ok = NodeKeys.revoke("mm1")
      assert_hidden(ios, hosting)

      # Turning one on for it is refused; turning one off still works.
      assert Skills.enable(xcode.id, {:machine, "mm1"}) ==
               {:error, "There's no machine called mm1."}

      :ok = NodeKeys.forget("mm1")
      assert_hidden(ios, hosting)

      machine!("mm1")
      assert Skills.scopes(ios.id) == [:blip, {:machine, "mm1"}]
      assert Skills.scopes(hosting.id) == [{:machine, "mm1"}, {:machine, "mp1"}]

      assert Enum.map(Skills.machine_skills(), fn {id, skills} -> {id, names(skills)} end) == [
               {"mm1", ["hosting-private-apps", "ios-simulators"]},
               {"mp1", ["hosting-private-apps"]}
             ]

      assert {:ok, _text, %{"machines" => ["mm1", "mp1"]}} = load(:blip, "hosting-private-apps")
    end

    defp assert_hidden(ios, hosting) do
      assert Skills.scopes(ios.id) == [:blip]
      assert Skills.scopes(hosting.id) == [{:machine, "mp1"}]

      assert [
               %{skill: %{name: "hosting-private-apps"}, scopes: [{:machine, "mp1"}]},
               %{skill: %{name: "ios-simulators"}, scopes: [:blip]},
               %{skill: %{name: "xcode"}, scopes: []}
             ] = Skills.list()

      assert [{"mp1", [%Skill{name: "hosting-private-apps"}]}] = Skills.machine_skills()
      assert {:ok, _text, %{"machines" => ["mp1"]}} = load(:blip, "hosting-private-apps")

      # ios-simulators is still Blip's own, but no longer loads as mm1's.
      assert {:ok, _text, details} = load(:blip, "ios-simulators")
      refute Map.has_key?(details, "machines")

      garden = project!("Garden #{System.unique_integer([:positive])}")

      assert load({:project, garden.id}, "ios-simulators") ==
               {:error,
                "There's no skill called ios-simulators turned on here or for a machine. " <>
                  "For machines: mp1 has hosting-private-apps."}
    end

    # Which skill loads, own or machine, and the error's names are
    # Rules.find_offered/2's (test/core/skills/rules_test.exs); this checks
    # the commit wiring once.
    test "load_tx/3 loads a machine's skill for Blip and for a project, naming the machines" do
      machine!("mm1")
      machine!("mp1")
      garden = project!("Garden")
      ios = skill!("ios-simulators")
      :ok = Skills.enable(ios.id, {:machine, "mp1"})
      :ok = Skills.enable(ios.id, {:machine, "mm1"})

      for scope <- [:blip, {:project, garden.id}] do
        assert load(scope, " iOS-Simulators ") ==
                 {:ok, Prompt.loaded(ios, ["mm1", "mp1"]),
                  %{
                    "skill" => "ios-simulators",
                    "version" => 1,
                    "full_output" => Prompt.full_output_hint("ios-simulators"),
                    "machines" => ["mm1", "mp1"]
                  }}
      end
    end

    test "deleting a skill deletes its machine rows" do
      machine!("mm1")
      ios = skill!("ios-simulators")
      :ok = Skills.enable(ios.id, {:machine, "mm1"})
      :ok = NodeKeys.revoke("mm1")

      assert Skills.delete(ios.id) == :ok
      assert Repo.aggregate(Enablement, :count) == 0
    end
  end
end
