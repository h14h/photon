defmodule Photon.Threads.RulesTest do
  @moduledoc "Thread titles and how the context-file tools describe files (sections 2.4 and 3.3)."

  use Photon.Case, async: true

  alias Photon.Projects.ContextFile
  alias Photon.Threads.Rules

  defp file(name, content, updated_by, at) do
    %ContextFile{
      name: name,
      content: content,
      updated_by: updated_by,
      updated_at: DateTime.from_naive!(at, "Etc/UTC")
    }
  end

  describe "title/1" do
    test "is the first line that isn't blank, its whitespace collapsed" do
      assert Rules.title("\n  \n  Fix   the\tpump  \nand then the valves") == "Fix the pump"
    end

    test "cuts a long line to 60 characters at a word boundary and adds ..." do
      line =
        "Check every zone of the irrigation system and write down which valves stick open in the cold"

      title = Rules.title(line)
      assert title == "Check every zone of the irrigation system and write down..."
      assert String.length(String.trim_trailing(title, "...")) <= 60
    end

    test "keeps a line of exactly 60 characters whole" do
      line = String.duplicate("a", 60)
      assert Rules.title(line) == line
    end

    test "cuts one long word" do
      assert Rules.title(String.duplicate("a", 70)) == String.duplicate("a", 60) <> "..."
    end

    test "has a fallback for a message with no text" do
      assert Rules.title(" \n ") == "Untitled thread"
    end
  end

  describe "listing/3" do
    test "names this thread as you, the owner as the user and another thread by its title" do
      files = [
        file("zones.md", "a", "c_other", ~N[2026-10-07 09:00:00]),
        file("notes.md", String.duplicate("x", 1_234), "c_me", ~N[2026-10-07 14:03:59]),
        file("plan.md", "", "owner", ~N[2026-10-07 11:30:00])
      ]

      assert Rules.listing(files, "c_me", %{"c_other" => "Fix the pump"}) ==
               """
               - notes.md (1,234 characters, changed 2026-10-07 14:03 UTC by you)
               - plan.md (0 characters, changed 2026-10-07 11:30 UTC by the user)
               - zones.md (1 character, changed 2026-10-07 09:00 UTC by thread "Fix the pump")\
               """
    end

    test "says another thread when it doesn't know its title" do
      files = [file("notes.md", "hi", "c_gone", ~N[2026-10-07 14:03:00])]
      assert Rules.listing(files, "c_me", %{}) =~ "by another thread)"
    end

    test "says when there are no files" do
      assert Rules.listing([], "c_me", %{}) == "This project has no context files yet."
    end
  end

  test "file_header/3 is the first line of a read" do
    notes = file("notes.md", "héllo", "owner", ~N[2026-10-07 14:03:00])

    assert Rules.file_header(notes, "c_me", %{}) ==
             "notes.md, 5 characters, changed 2026-10-07 14:03 UTC by the user:"
  end

  test "missing_file/2 lists the files there are" do
    assert Rules.missing_file("todo.md", []) ==
             "There's no todo.md. This project has no context files yet."

    assert Rules.missing_file("todo.md", ["notes.md", "zones.md"]) ==
             "There's no todo.md. This project's context files are: notes.md, zones.md."
  end

  test "characters/1 counts code points with thousands separators" do
    assert Rules.characters("") == "0 characters"
    assert Rules.characters("é") == "1 character"
    assert Rules.characters(String.duplicate("a", 123_456)) == "123,456 characters"
  end
end
