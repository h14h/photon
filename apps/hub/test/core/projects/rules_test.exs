defmodule Photon.Projects.RulesTest do
  @moduledoc "The rules for projects and context files."

  use Photon.Case, async: true

  alias Photon.Projects.{ContextFile, Project, Rules}

  @purpose "Keep the garden's irrigation running through winter. It has three zones."

  defp file(version), do: %ContextFile{name: "notes.md", content: "", version: version}

  describe "project/2" do
    test "requires a purpose, trimmed" do
      assert Rules.project(%{"purpose" => "  \n "}, nil) ==
               {:error, %{purpose: "Say what the project is for."}}

      assert Rules.project(%{}, nil) == {:error, %{purpose: "Say what the project is for."}}

      assert {:ok, %{purpose: "Fix the pump."}} =
               Rules.project(%{purpose: "  Fix the pump. "}, nil)
    end

    test "caps the purpose at 4,000 characters" do
      assert {:ok, _} = Rules.project(%{"purpose" => String.duplicate("a", 4_000)}, nil)

      assert {:error, %{purpose: "Keep the purpose under 4,000 characters" <> _}} =
               Rules.project(%{"purpose" => String.duplicate("a", 4_001)}, nil)
    end

    test "trims the name, collapses its whitespace and caps it at 60 characters" do
      assert {:ok, %{name: "Garden notes"}} =
               Rules.project(%{"purpose" => "x", "name" => "  Garden \t  notes "}, nil)

      assert {:ok, _} =
               Rules.project(%{"purpose" => "x", "name" => String.duplicate("n", 60)}, nil)

      assert {:error, %{name: _}} =
               Rules.project(%{"purpose" => "x", "name" => String.duplicate("n", 61)}, nil)
    end

    test "reports every field's error at once" do
      assert {:error, %{purpose: _, name: _}} =
               Rules.project(%{"purpose" => "", "name" => String.duplicate("n", 61)}, nil)
    end

    test "makes a blank name from the purpose" do
      assert Rules.project(%{"purpose" => @purpose, "name" => " "}, nil) ==
               {:ok, %{name: "Keep the garden's irrigation running", purpose: @purpose}}
    end

    test "on edit, keeps what params leave out and makes a cleared name again" do
      current = %Project{name: "Garden", purpose: @purpose, slug: "garden"}

      assert Rules.project(%{"name" => "Yard"}, current) ==
               {:ok, %{name: "Yard", purpose: @purpose}}

      assert Rules.project(%{"purpose" => "Fix the pump."}, current) ==
               {:ok, %{name: "Garden", purpose: "Fix the pump."}}

      assert Rules.project(%{"name" => ""}, current) ==
               {:ok, %{name: "Keep the garden's irrigation running", purpose: @purpose}}
    end
  end

  describe "name_from/1" do
    test "takes the first sentence of the first line" do
      assert Rules.name_from("Fix the pump. Then the valves.") == "Fix the pump"
      assert Rules.name_from("Is the pump fixed? Check.") == "Is the pump fixed"

      assert Rules.name_from("Trip to Lisbon\nFlights, hotel, a day in Sintra.") ==
               "Trip to Lisbon"

      assert Rules.name_from("\n  Version 1.2 release notes") == "Version 1.2 release notes"
    end

    test "cuts at a word boundary to 40 characters and drops trailing punctuation" do
      assert Rules.name_from(@purpose) == "Keep the garden's irrigation running"

      assert Rules.name_from("Pump, valves, timers, sensors, pipes, and hoses") ==
               "Pump, valves, timers, sensors, pipes"

      assert Rules.name_from(String.duplicate("x", 50)) == String.duplicate("x", 40)
    end

    test "falls back when nothing is left" do
      assert Rules.name_from("...") == "Untitled project"
    end
  end

  describe "slug/1" do
    test "drops accents and lowercases" do
      assert Rules.slug("Café Notes") == "cafe-notes"
      assert Rules.slug("Ångström Über") == "angstrom-uber"
    end

    test "turns runs of other characters into one hyphen and trims them" do
      assert Rules.slug("Fix the pump!!  (zone 2)") == "fix-the-pump-zone-2"
      assert Rules.slug("  --Garden's irrigation--  ") == "garden-s-irrigation"
    end

    test "cuts to 40 characters, back to a hyphen past character 20 when a word is split" do
      assert Rules.slug("Irrigation schedule for the vegetable gardens") ==
               "irrigation-schedule-for-the-vegetable"

      # The cut falls just before a hyphen: no word is split, nothing is cut back.
      assert Rules.slug("abcdefghij abcdefghij abcdefghij abcdefg xyz") ==
               "abcdefghij-abcdefghij-abcdefghij-abcdefg"

      # No hyphen past character 20: a hard cut.
      long = "short " <> String.duplicate("x", 50)
      assert Rules.slug(long) == "short-" <> String.duplicate("x", 34)
    end

    test "never ends in a hyphen after a cut" do
      slug = Rules.slug(String.duplicate("a", 39) <> " b")
      assert slug == String.duplicate("a", 39)
    end

    test "is project when nothing is left, and never a reserved segment" do
      assert Rules.slug("!!!") == "project"
      assert Rules.slug("日本") == "project"
      assert Rules.slug("New") == "new-project"
      assert Rules.slug("new things") == "new-things"
    end
  end

  test "unique_slug/2 appends -2, -3 until free" do
    assert Rules.unique_slug("garden", []) == "garden"
    assert Rules.unique_slug("garden", ["garden-more"]) == "garden"
    assert Rules.unique_slug("garden", ["garden"]) == "garden-2"
    assert Rules.unique_slug("garden", ["garden", "garden-2"]) == "garden-3"
  end

  describe "file_name/1" do
    test "adds .md and keeps a name that has it in any case" do
      assert Rules.file_name(" notes ") == {:ok, "notes.md"}
      assert Rules.file_name("README.md") == {:ok, "README.md"}
      assert Rules.file_name("Plan.MD") == {:ok, "Plan.MD"}
      assert Rules.file_name("v1.2_pump-log") == {:ok, "v1.2_pump-log.md"}
    end

    test "refuses folders, climbing, hidden files, spaces and long names" do
      long = String.duplicate("a", 62) <> ".md"
      assert String.length(long) == 65

      for name <- ["../x", "a/b.md", ".hidden.md", long, "my notes.md", "", "a..b.md"] do
        assert {:error, ~s(A file name uses letters, digits, ".", "_" and "-", like "notes.md".)} =
                 Rules.file_name(name),
               name
      end

      assert {:ok, _} = Rules.file_name(String.duplicate("a", 61) <> ".md")
    end
  end

  test "key/1 ignores case and a missing .md" do
    assert Rules.key("Notes") == "notes.md"
    assert Rules.key(" NOTES.md ") == "notes.md"
  end

  test "content/2 allows 100,000 characters and no more" do
    assert Rules.content("notes.md", String.duplicate("é", 100_000)) == :ok

    assert Rules.content("notes.md", String.duplicate("a", 100_001)) ==
             {:error,
              "notes.md would be 100,001 characters; the limit is 100,000. " <>
                "Split it into more than one file."}
  end

  test "save_check/2" do
    assert Rules.save_check(nil, nil) == :ok
    assert Rules.save_check(file(3), 3) == :ok
    assert Rules.save_check(file(4), 3) == :stale
    assert Rules.save_check(file(1), nil) == :exists
    # Deleted since the editor loaded it: saving creates it again.
    assert Rules.save_check(nil, 3) == :ok
  end

  describe "edit/4" do
    test "replaces a passage found once" do
      assert Rules.edit("notes.md", "zone 1 ok\nzone 2 stuck\n", "zone 2 stuck", "zone 2 fixed") ==
               {:ok, "zone 1 ok\nzone 2 fixed\n"}
    end

    test "says when the passage isn't there" do
      assert Rules.edit("notes.md", "hello", "bye", "x") ==
               {:error, "old_text wasn't found in notes.md."}
    end

    test "says how many times an ambiguous passage appears" do
      assert Rules.edit("notes.md", "ok ok ok", "ok", "fine") ==
               {:error, "old_text appears 3 times in notes.md; give more of the passage."}
    end

    test "counts occurrences that overlap" do
      assert Rules.edit("notes.md", "ababab", "abab", "x") ==
               {:error, "old_text appears 2 times in notes.md; give more of the passage."}

      assert Rules.edit("notes.md", "- [ ] - [ ] - [ ] b", "- [ ] - [ ] ", "- [x] ") ==
               {:error, "old_text appears 2 times in notes.md; give more of the passage."}
    end

    test "replaces a passage that ends the file" do
      assert Rules.edit("notes.md", "one two", "two", "2") == {:ok, "one 2"}
    end

    test "refuses an empty passage" do
      assert {:error, "old_text is empty" <> _} = Rules.edit("notes.md", "hello", "", "x")
    end
  end

  test "count/1 groups thousands" do
    assert Rules.count(0) == "0"
    assert Rules.count(999) == "999"
    assert Rules.count(1_234) == "1,234"
    assert Rules.count(123_456_789) == "123,456,789"
  end
end
