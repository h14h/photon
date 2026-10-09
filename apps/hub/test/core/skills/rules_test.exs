defmodule Photon.Skills.RulesTest do
  @moduledoc "The rules for skills."

  use Photon.Case, async: true

  alias Photon.Skills.Rules

  @name_message ~s(A skill's name uses lowercase letters, digits and hyphens, like "pdf-forms".)

  defp params(overrides) do
    Map.merge(
      %{"name" => "pdf-forms", "description" => "Fill in PDF forms.", "instructions" => "# PDF"},
      overrides
    )
  end

  describe "name/1" do
    test "takes lowercase letters, digits and single hyphens, trimmed" do
      assert Rules.name(" pdf-forms ") == {:ok, "pdf-forms"}
      assert Rules.name("a1-b2-c3") == {:ok, "a1-b2-c3"}
      assert Rules.name(String.duplicate("a", 64)) == {:ok, String.duplicate("a", 64)}
    end

    test "refuses other names with the rule and an example" do
      for name <- ["PDF", "-x", "x-", "a--b", "pdf forms", "pdf_forms", "", "café"] do
        assert Rules.name(name) == {:error, @name_message}, name
      end
    end

    test "refuses a name over 64 characters" do
      assert Rules.name(String.duplicate("a", 65)) ==
               {:error, "Keep the name to 64 characters or fewer."}
    end

    test "refuses the names the routes use" do
      for name <- ["new", "install"] do
        assert Rules.name(name) == {:error, "That name is taken by the app; pick another."}
      end
    end

    test "name_taken/1 says which name" do
      assert Rules.name_taken("pdf-forms") ==
               %{name: "There's already a skill called pdf-forms."}
    end
  end

  describe "suggest_name/1" do
    test "makes a name that follows the rule" do
      assert Rules.suggest_name("PDF Forms") == "pdf-forms"
      assert Rules.suggest_name("Café notes") == "cafe-notes"
      assert Rules.suggest_name("  --Release_Notes v2!  ") == "release-notes-v2"
      assert Rules.suggest_name("***") == "skill"
      assert Rules.suggest_name("") == "skill"
      assert Rules.suggest_name("New") == "new-skill"
    end

    test "cuts to 64 characters without a trailing hyphen" do
      name = Rules.suggest_name(String.duplicate("a", 63) <> " b")
      assert name == String.duplicate("a", 63)
      assert {:ok, _} = Rules.name(Rules.suggest_name(String.duplicate("word ", 40)))
    end
  end

  describe "description/1" do
    test "is required, trimmed" do
      assert Rules.description("  \n ") == {:error, "Say when an agent should use this skill."}
      assert Rules.description(" Fill in PDF forms. ") == {:ok, "Fill in PDF forms."}
    end

    test "is capped at 1,024 characters" do
      assert {:ok, _} = Rules.description(String.duplicate("é", 1_024))

      assert Rules.description(String.duplicate("a", 1_025)) ==
               {:error,
                "Keep the description under 1,024 characters; agents read it on every request."}
    end
  end

  describe "instructions/2" do
    test "are required after trimming, with \\n line ends" do
      assert Rules.instructions("pdf-forms", " \r\n ") == {:error, "A skill needs instructions."}

      assert Rules.instructions("pdf-forms", "\n# PDF\r\n\r\nStep one.\n") ==
               {:ok, "# PDF\n\nStep one."}
    end

    test "are capped at 50,000 code points" do
      assert {:ok, _} = Rules.instructions("pdf-forms", String.duplicate("é", 50_000))

      assert Rules.instructions("pdf-forms", String.duplicate("é", 50_001)) ==
               {:error,
                "pdf-forms's instructions are 50,001 characters; the limit is 50,000, " <>
                  "since a skill is loaded whole into the conversation."}

      assert {:error, "The instructions are 61,234 characters;" <> _} =
               Rules.instructions(nil, String.duplicate("a", 61_234))
    end
  end

  describe "skill/2" do
    test "checks every field and returns them trimmed" do
      assert Rules.skill(params(%{"name" => " pdf-forms "}), nil) ==
               {:ok,
                %{name: "pdf-forms", description: "Fill in PDF forms.", instructions: "# PDF"}}

      assert {:ok, %{name: "x"}} =
               Rules.skill(%{name: "x", description: "d", instructions: "i"}, nil)
    end

    test "gives every field's error at once" do
      assert Rules.skill(%{}, nil) ==
               {:error,
                %{
                  name: @name_message,
                  description: "Say when an agent should use this skill.",
                  instructions: "A skill needs instructions."
                }}
    end

    test "names the skill in the instructions' message only when the name is valid" do
      long = String.duplicate("a", 50_001)

      assert {:error, %{name: _, instructions: "The instructions are" <> _}} =
               Rules.skill(params(%{"name" => "PDF", "instructions" => long}), nil)
    end

    test "keeps a field the params leave out" do
      current = %{name: "pdf-forms", description: "Old.", instructions: "# Old"}

      assert Rules.skill(%{"description" => "New."}, current) ==
               {:ok, %{name: "pdf-forms", description: "New.", instructions: "# Old"}}
    end
  end

  describe "save_check/2" do
    test "is :ok at the loaded version and :stale otherwise" do
      assert Rules.save_check(3, 3) == :ok
      assert Rules.save_check(4, 3) == :stale
      assert Rules.save_check(3, nil) == :stale
    end
  end

  describe "enable_check/1" do
    test "allows up to 30 skills per scope" do
      assert Rules.enable_check(0) == :ok
      assert Rules.enable_check(29) == :ok

      assert Rules.enable_check(30) ==
               {:error,
                "30 skills are on here already. Turn one off first: agents read every " <>
                  "enabled skill's description on every request."}
    end
  end

  describe "by_machine/2" do
    test "groups skills by machine in known's order, keeping the skills' order" do
      pairs = [{"mp1", "alpha"}, {"mm1", "beta"}, {"mp1", "gamma"}, {"local", "delta"}]

      assert Rules.by_machine(pairs, ["local", "mm1", "mp1"]) == [
               {"local", ["delta"]},
               {"mm1", ["beta"]},
               {"mp1", ["alpha", "gamma"]}
             ]
    end

    test "drops machines it doesn't know and leaves out known ones with no skills" do
      pairs = [{"gone", "alpha"}, {"mm1", "beta"}]
      assert Rules.by_machine(pairs, ["local", "mm1", "mp1"]) == [{"mm1", ["beta"]}]
    end

    test "is empty with no pairs" do
      assert Rules.by_machine([], ["mm1"]) == []
      assert Rules.by_machine([{"mm1", "alpha"}], []) == []
    end
  end

  describe "find_offered/2" do
    @ios %{name: "ios-simulators", version: 1}
    @hosting %{name: "hosting-private-apps", version: 3}
    @pdf %{name: "pdf-forms", version: 2}

    test "finds a skill in the agent's own set" do
      assert Rules.find_offered(%{own: [@pdf], machines: []}, "pdf-forms") == {:own, @pdf}
    end

    test "the own set wins over a machine that has the same skill" do
      # On for the agent and for mm1: it applies to all the agent's work,
      # so it loads without naming mm1.
      own_ios = Map.put(@ios, :listed, :own)
      offered = %{own: [@pdf, own_ios], machines: [{"mm1", [@ios]}]}
      assert Rules.find_offered(offered, "ios-simulators") == {:own, own_ios}
    end

    test "names every machine that has it, in the order given" do
      offered = %{
        own: [@pdf],
        machines: [{"local", [@hosting]}, {"mm1", [@ios]}, {"mp1", [@hosting, @ios]}]
      }

      assert Rules.find_offered(offered, "ios-simulators") == {:machines, @ios, ["mm1", "mp1"]}

      assert Rules.find_offered(offered, "hosting-private-apps") ==
               {:machines, @hosting, ["local", "mp1"]}
    end

    test "with nothing called that, gives the own names and each machine's" do
      offered = %{own: [@pdf], machines: [{"mm1", [@hosting, @ios]}, {"mp1", [@hosting]}]}

      assert Rules.find_offered(offered, "xcode") ==
               {:none, ["pdf-forms"],
                [
                  {"mm1", ["hosting-private-apps", "ios-simulators"]},
                  {"mp1", ["hosting-private-apps"]}
                ]}
    end

    test "with nothing called that and no own skills, gives only the machines'" do
      offered = %{own: [], machines: [{"mm1", [@ios]}]}
      assert Rules.find_offered(offered, "xcode") == {:none, [], [{"mm1", ["ios-simulators"]}]}
    end

    test "with nothing on anywhere, gives two empty lists" do
      assert Rules.find_offered(%{own: [], machines: []}, "xcode") == {:none, [], []}
    end
  end

  describe "mentions/2 with a folder listing" do
    @left_out ["scripts/fill.py", "reference.md", "forms.md", "assets/logo.png"]

    test "finds the left-out paths the instructions name, as written or as a link" do
      instructions = """
      Run `python scripts/fill.py form.pdf`. See [the reference](./reference.md#fields).
      """

      assert Rules.mentions(instructions, @left_out) == ["scripts/fill.py", "reference.md"]
    end

    test "doesn't match a path inside a longer one" do
      instructions = "See my-reference.md, other/forms.md and forms.mdx."
      assert Rules.mentions(instructions, @left_out) == []
    end

    test "is empty when nothing is mentioned" do
      assert Rules.mentions("# Plain instructions", @left_out) == []
    end
  end

  describe "mentions/2 without a folder listing" do
    test "finds relative link targets and backticked paths, in order" do
      instructions = """
      Read [the reference](reference.md) and ![logo](assets/logo.png).
      Then run `scripts/fill.py` or `bash ./tools/run.sh --fast`.
      Not [a site](https://example.com/x.py), [an anchor](#usage) or [mail](mailto:a@b.c).
      Not `/usr/bin/env.py` or `https://example.com/x.js` either.

      ```bash
      python scripts/fill.py your_form.py
      cat references/fields.md
      ```

      [Again](reference.md)
      """

      assert Rules.mentions(instructions, []) == [
               "reference.md",
               "assets/logo.png",
               "scripts/fill.py",
               "tools/run.sh",
               "references/fields.md"
             ]
    end

    test "a backticked script in a paste is a mention" do
      assert Rules.mentions("Fill it with `scripts/fill.py`.", []) == ["scripts/fill.py"]
    end

    test "is empty for instructions that name no files" do
      assert Rules.mentions("# PDF\n\nUse `pdftk` and [the docs](https://pdftk.org).", []) == []
    end
  end
end
