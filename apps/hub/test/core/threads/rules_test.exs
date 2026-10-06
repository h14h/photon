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

    test "cuts a long line to 50 characters at a word boundary and adds ..." do
      line =
        "Check every zone of the irrigation system and write down which valves stick open in the cold"

      title = Rules.title(line)
      assert title == "Check every zone of the irrigation system and..."
      assert String.length(String.trim_trailing(title, "...")) <= 50
    end

    test "keeps a line of exactly 50 characters whole" do
      line = String.duplicate("a", 50)
      assert Rules.title(line) == line
    end

    test "cuts one long word" do
      assert Rules.title(String.duplicate("a", 70)) == String.duplicate("a", 50) <> "..."
    end

    test "leaves out Markdown's marks" do
      assert Rules.title("## Fix the `pump`\nIt sticks.") == "Fix the pump"
      assert Rules.title("- read **notes.md** first") == "read notes.md first"
      assert Rules.title("> 1. check _zone 2_ valves") == "1. check zone 2 valves"
      assert Rules.title("snake_case_name stays") == "snake_case_name stays"
    end

    test "titles a schedule's message by its prompt" do
      assert Rules.title("[Scheduled] Check the backups") == "Check the backups"
    end

    test "has a fallback for a message with no text" do
      assert Rules.title(" \n ") == "Untitled thread"
      assert Rules.title("```") == "Untitled thread"
    end
  end

  describe "the model's title" do
    test "the request shows the start of the first message and the first answer" do
      %{system: system, messages: [message]} = Rules.title_request("read notes.md", "Zone 2.")
      assert system =~ "2 to 6 words"
      text = PhotonCore.Message.text_of(message)
      assert text =~ "Its first answer:\n<<<\nZone 2.\n>>>"
      assert Rules.requested_message(text) == "read notes.md"

      %{messages: [message]} = Rules.title_request(String.duplicate("x", 2_000), nil)
      text = PhotonCore.Message.text_of(message)
      assert String.length(Rules.requested_message(text)) == 1_503
      assert text =~ "(none yet)"

      assert Rules.requested_message("Something else") == nil
    end

    test "is its answer's first line, without quotes, marks or an ending" do
      assert Rules.model_title("Check disk space on local") == {:ok, "Check disk space on local"}
      assert Rules.model_title("\n\"Fix the pump.\"\n") == {:ok, "Fix the pump"}
      assert Rules.model_title("Title: **Weekly checklist**!") == {:ok, "Weekly checklist"}
      assert Rules.model_title("\u201cZone 2 valves\u201d") == {:ok, "Zone 2 valves"}
      assert Rules.model_title("# Plan the beds\nBecause...") == {:ok, "Plan the beds"}
    end

    test "is cut at 50 characters, and isn't one when it's empty or too long" do
      assert {:ok, title} =
               Rules.model_title("Investigate intermittent irrigation controller disconnections")

      assert title == "Investigate intermittent irrigation controller"

      assert Rules.model_title("  \n ") == :error
      assert Rules.model_title("\"\"") == :error

      assert Rules.model_title("This is a whole sentence about the thread that goes on and on") ==
               :error
    end
  end

  describe "rename/1" do
    test "collapses whitespace, cuts at 80 characters and refuses a blank" do
      assert Rules.rename("  Fix\n the   pump ") == {:ok, "Fix the pump"}
      assert {:ok, long} = Rules.rename(String.duplicate("a", 100))
      assert String.length(long) == 80
      assert Rules.rename(" \n ") == {:error, :blank}
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
