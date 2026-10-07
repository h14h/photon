defmodule PhotonWeb.SkillTextTest do
  @moduledoc "The skills pages' words for where a skill is on, how it arrived and its install notes."

  use Photon.Case, async: true

  alias Photon.Skills.Skill
  alias PhotonWeb.SkillText

  @names %{"p_garden" => "Garden", "p_house" => "House", "p_shed" => "Shed"}

  describe "scopes/2" do
    test "names Blip and the projects, joined as a sentence" do
      assert SkillText.scopes([], @names) == "Off everywhere"
      assert SkillText.scopes([:blip], @names) == "On for Blip"
      assert SkillText.scopes([{:project, "p_garden"}], @names) == "On for Garden"
      assert SkillText.scopes([:blip, {:project, "p_garden"}], @names) == "On for Blip and Garden"

      assert SkillText.scopes([:blip, {:project, "p_garden"}, {:project, "p_house"}], @names) ==
               "On for Blip, Garden and House"

      assert SkillText.scopes(
               [{:project, "p_garden"}, {:project, "p_house"}, {:project, "p_shed"}],
               @names
             ) == "On for Garden, House and Shed"
    end

    test "names a machine as a machine" do
      assert SkillText.scopes([:blip, {:project, "p_garden"}, {:machine, "mm1"}], @names) ==
               "On for Blip, Garden and machine mm1"

      assert SkillText.scopes([{:machine, "mm1"}], @names) == "On for machine mm1"
    end

    test "leaves out a project it has no name for" do
      assert SkillText.scopes([{:project, "p_gone"}], @names) == "Off everywhere"
      assert SkillText.scopes([:blip, {:project, "p_gone"}], @names) == "On for Blip"
    end
  end

  test "origin/1 says how a skill arrived" do
    assert SkillText.origin(%Skill{origin: "written"}) == "Written here"
    assert SkillText.origin(%Skill{origin: "pasted"}) == "Pasted"

    assert SkillText.origin(%Skill{
             origin: "fetched",
             source_url: "https://github.com/o/r/blob/main/pdf-forms/SKILL.md"
           }) == "From github.com/o/r/blob/main/pdf-forms/SKILL.md"

    assert SkillText.origin(%Skill{origin: "fetched"}) == "Installed"
    assert SkillText.origin(%Skill{origin: "carried"}) == "Installed"
  end

  test "place/1 drops the scheme and a trailing slash" do
    assert SkillText.place("https://github.com/o/r/") == "github.com/o/r"
    assert SkillText.place("http://example.com/SKILL.md") == "example.com/SKILL.md"
  end

  test "notes/1 splits install notes into lines" do
    assert SkillText.notes(nil) == []
    assert SkillText.notes("") == []

    assert SkillText.notes("Left out: a.py.\n\nIgnored front matter: license.\n") ==
             ["Left out: a.py.", "Ignored front matter: license."]
  end
end
