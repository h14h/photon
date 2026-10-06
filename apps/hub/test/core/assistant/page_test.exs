defmodule Photon.Assistant.PageTest do
  @moduledoc "The page under Blip: what a path is about, the page's label, and the note."

  use Photon.Case, async: true

  alias Photon.Assistant.Page

  @project %{id: "p_1", slug: "garden", name: "Garden"}
  @thread %{id: "c_1", title: "Fix the pump"}

  defp facts(overrides \\ %{}) do
    Map.merge(
      %{
        purpose: "Keep the garden's irrigation running through winter.",
        files: ["notes.md", "zones.md"],
        threads: [
          %{id: "c_1", title: "Fix the pump", running?: false},
          %{id: "c_2", title: "Plan the beds", running?: true}
        ]
      },
      overrides
    )
  end

  defp lines(note), do: String.split(note, "\n")

  describe "at/1" do
    test "every page inside a project is about it, the new-thread and new-file pages too" do
      for path <-
            ~w(/projects/x /projects/x/threads/new /projects/x/files/new /projects/x/other/page),
          path <- [path, path <> "/"] do
        assert Page.at(path) == {:project, "x"}, path
      end
    end

    test "a context file's page and a thread's page name what they show" do
      for suffix <- ["", "/"] do
        assert Page.at("/projects/x/files/a.md" <> suffix) == {:file, "x", "a.md"}
        assert Page.at("/projects/x/threads/c_123" <> suffix) == {:thread, "x", "c_123"}
      end
    end

    test "pages outside a project, and the new-project page, are about nothing" do
      for path <- ~w(/ /nodes /settings /projects /projects/new /projects/new/x),
          path <- [path, path <> "/"] do
        assert Page.at(path) == nil, path
      end
    end
  end

  test "labels a project's page, a file's and a thread's" do
    assert Page.of_project(@project)["label"] == "Garden"
    assert Page.of_file(@project, "notes.md")["label"] == "Garden / notes.md"
    assert Page.of_thread(@project, @thread)["label"] == "Garden / Fix the pump"

    assert %{
             "kind" => "thread",
             "project_id" => "p_1",
             "slug" => "garden",
             "name" => "Garden",
             "thread_id" => "c_1",
             "title" => "Fix the pump",
             "file" => nil
           } = Page.of_thread(@project, @thread)

    assert %{"kind" => "file", "file" => "notes.md", "thread_id" => nil} =
             Page.of_file(@project, "notes.md")
  end

  describe "note/2" do
    test "a project's page: the project, its purpose, files and threads" do
      assert Page.note(Page.of_project(@project), facts()) ==
               """
               [Looking at the project "Garden", folder "garden" in each machine's workspace]
               Purpose: Keep the garden's irrigation running through winter.
               Context files: notes.md, zones.md
               Threads: "Fix the pump" (idle), "Plan the beds" (running)\
               """
    end

    test "says when a project has no files or threads yet" do
      note = Page.note(Page.of_project(@project), facts(%{files: [], threads: []}))
      assert "Context files: none yet" in lines(note)
      assert "Threads: none yet" in lines(note)
    end

    test "a file's page names the file and includes its content as last saved" do
      page = Page.of_file(@project, "notes.md")
      note = Page.note(page, facts(%{file: %{content: "Zone 2 valve: stuck."}}))

      assert hd(lines(note)) ==
               ~s([Looking at notes.md in the project "Garden", folder "garden" in each machine's workspace])

      assert note =~
               "notes.md as last saved, between the lines:\n-----\nZone 2 valve: stuck.\n-----"
    end

    test "a file's page says when the file is empty or was deleted" do
      page = Page.of_file(@project, "notes.md")

      assert Page.note(page, facts(%{file: %{content: ""}})) =~
               "notes.md is empty, as last saved."

      assert Page.note(page, facts(%{file: nil})) =~ "notes.md doesn't exist anymore"
    end

    test "a thread's page: the thread's state, its latest answer, and the other threads" do
      page = Page.of_thread(@project, @thread)

      note =
        Page.note(
          page,
          facts(%{thread: %{running?: false, answer: "The zone 2 valve is stuck open."}})
        )

      assert lines(note) == [
               ~s([Looking at the thread "Fix the pump" in the project "Garden", folder "garden" in each machine's workspace]),
               "Purpose: Keep the garden's irrigation running through winter.",
               "Context files: notes.md, zones.md",
               ~s(Other threads: "Plan the beds" \(running\)),
               ~s(The thread is idle. Its latest answer: "The zone 2 valve is stuck open.")
             ]
    end

    test "a thread that hasn't answered yet, alone in its project" do
      threads = [%{id: "c_1", title: "Fix the pump", running?: true}]
      facts = facts(%{threads: threads, thread: %{running?: true, answer: nil}})
      note = Page.note(Page.of_thread(@project, @thread), facts)

      refute note =~ "threads:"
      assert List.last(lines(note)) == "The thread is running. It hasn't answered yet."
    end
  end

  describe "note/2 bounds" do
    test "cuts a long purpose to 1,000 characters" do
      purpose = String.duplicate("a", 1_200)
      note = Page.note(Page.of_project(@project), facts(%{purpose: purpose}))
      assert ("Purpose: " <> String.duplicate("a", 1_000) <> "...") in lines(note)
    end

    test "names 30 files and 10 threads, and counts the rest" do
      files = for i <- 1..31, do: "f#{i}.md"
      threads = for i <- 1..11, do: %{id: "c_#{i}", title: "t#{i}", running?: false}
      note = Page.note(Page.of_project(@project), facts(%{files: files, threads: threads}))

      assert note =~ "f30.md, and 1 more"
      refute note =~ "f31.md"
      assert note =~ ~s{"t10" (idle), and 1 more}
      refute note =~ ~s("t11")
    end

    test "includes the first 4,000 characters of a long file, and says how long it is" do
      content = String.duplicate("x", 4_000) <> String.duplicate("y", 1_000)
      note = Page.note(Page.of_file(@project, "notes.md"), facts(%{file: %{content: content}}))

      assert note =~
               String.duplicate("x", 4_000) <> "\n-----\n(cut; the file has 5,000 characters)"

      refute note =~ "xy"
    end

    test "includes the last 1,500 characters of a long answer" do
      answer = String.duplicate("a", 500) <> String.duplicate("b", 1_500)
      facts = facts(%{thread: %{running?: false, answer: answer}})
      note = Page.note(Page.of_thread(@project, @thread), facts)

      assert List.last(lines(note)) ==
               ~s(The thread is idle. The end of its latest answer: "...#{String.duplicate("b", 1_500)}")
    end
  end
end
