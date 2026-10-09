defmodule Photon.Skills.SourceTest do
  @moduledoc "Where skills come from, with plain inputs."

  use Photon.Case, async: true

  alias Photon.Skills.Source

  @not_a_link "Give an https:// link to a SKILL.md, or to a folder on GitHub."

  defp gh(owner, repo, ref, path, kind),
    do: {:ok, {:github, %{owner: owner, repo: repo, ref: ref, path: path, kind: kind}}}

  defp link(ref, path, kind), do: %{owner: "o", repo: "r", ref: ref, path: path, kind: kind}

  # A GitHub tree answer listing `files` (and the folders above them).
  defp tree(files, truncated \\ false) do
    folders =
      files
      |> Enum.flat_map(fn file ->
        parts = String.split(file, "/")
        for n <- 1..(length(parts) - 1)//1, do: parts |> Enum.take(n) |> Enum.join("/")
      end)
      |> Enum.uniq()

    entries =
      Enum.map(folders, &%{"path" => &1, "type" => "tree"}) ++
        Enum.map(files, &%{"path" => &1, "type" => "blob"})

    %{"sha" => "abc", "tree" => entries, "truncated" => truncated}
  end

  # GitHub's answer for the folder `folder` (`Source.tree_url/1`): the
  # files under it, relative to it.
  defp listing(files, folder, truncated \\ false) do
    files
    |> Enum.filter(&(folder == "" or String.starts_with?(&1, folder <> "/")))
    |> Enum.map(&if(folder == "", do: &1, else: String.replace_prefix(&1, folder <> "/", "")))
    |> tree(truncated)
  end

  defp skill_md(name, body \\ "Do it.") do
    "---\nname: #{name}\ndescription: Use for #{name}.\n---\n\n#{body}\n"
  end

  describe "classify/1" do
    test "a repository's root, with or without .git and a trailing slash" do
      for url <- [
            "https://github.com/o/r",
            "https://github.com/o/r/",
            "https://github.com/o/r.git",
            "  https://www.github.com/o/r.git/  "
          ] do
        assert Source.classify(url) == gh("o", "r", nil, "", :folder), url
      end
    end

    test "a folder, with the ref as the first segment after tree" do
      assert Source.classify("https://github.com/o/r/tree/main/skills/pdf-forms") ==
               gh("o", "r", "main", "skills/pdf-forms", :folder)

      assert Source.classify("https://github.com/o/r/tree/main/skills/pdf-forms/") ==
               gh("o", "r", "main", "skills/pdf-forms", :folder)

      assert Source.classify("https://github.com/o/r/tree/v2") == gh("o", "r", "v2", "", :folder)

      # A branch with a slash in it: the first segment is taken as the ref.
      assert Source.classify("https://github.com/o/r/tree/feature/x/skills") ==
               gh("o", "r", "feature", "x/skills", :folder)
    end

    test "a file on github.com or its raw address" do
      assert Source.classify("https://github.com/o/r/blob/main/skills/pdf-forms/SKILL.md") ==
               gh("o", "r", "main", "skills/pdf-forms/SKILL.md", :file)

      assert Source.classify("https://raw.githubusercontent.com/o/r/main/skills/x/SKILL.md") ==
               gh("o", "r", "main", "skills/x/SKILL.md", :file)

      assert Source.classify(
               "https://raw.githubusercontent.com/o/r/refs/heads/dev/skills/x/SKILL.md"
             ) == gh("o", "r", "dev", "skills/x/SKILL.md", :file)
    end

    test "percent-encoded paths are decoded" do
      assert Source.classify("https://github.com/o/r/tree/main/my%20skills") ==
               gh("o", "r", "main", "my skills", :folder)
    end

    test "anything else is a file at that address" do
      for url <- [
            "https://example.com/skills/SKILL.md",
            "http://example.com/SKILL.md",
            "https://github.com/o",
            "https://github.com/o/r/issues/1",
            "https://github.com/o/r/blob/main"
          ] do
        assert Source.classify(url) == {:ok, {:web, url}}, url
      end
    end

    test "a link that isn't http or https is refused" do
      for url <- ["ftp://example.com/SKILL.md", "github.com/o/r", "", "file:///tmp/SKILL.md"] do
        assert Source.classify(url) == {:error, @not_a_link}, url
      end
    end
  end

  describe "GitHub addresses" do
    test "the API, raw and blob addresses, encoded" do
      link = link("main", "skills/pdf forms", :folder)

      assert Source.repo_url(link) == "https://api.github.com/repos/o/r"

      assert Source.tree_url(link) ==
               "https://api.github.com/repos/o/r/git/trees/main:skills/pdf%20forms?recursive=1"

      assert Source.tree_url(link("main", "skills/pdf forms/SKILL.md", :file)) ==
               "https://api.github.com/repos/o/r/git/trees/main:skills/pdf%20forms?recursive=1"

      assert Source.tree_url(link("main", "", :folder)) ==
               "https://api.github.com/repos/o/r/git/trees/main?recursive=1"

      assert Source.tree_url(link("main", "SKILL.md", :file)) ==
               "https://api.github.com/repos/o/r/git/trees/main?recursive=1"

      assert Source.raw_url(link, "skills/pdf forms/SKILL.md") ==
               "https://raw.githubusercontent.com/o/r/main/skills/pdf%20forms/SKILL.md"

      assert Source.blob_url(link, "skills/pdf forms/SKILL.md") ==
               "https://github.com/o/r/blob/main/skills/pdf%20forms/SKILL.md"
    end

    test "place/1 names the link as GitHub shows it" do
      assert Source.place(link(nil, "", :folder)) == "github.com/o/r"
      assert Source.place(link("main", "", :folder)) == "github.com/o/r/tree/main"
      assert Source.place(link("main", "skills", :folder)) == "github.com/o/r/tree/main/skills"

      assert Source.place(link("main", "skills/x/SKILL.md", :file)) ==
               "github.com/o/r/blob/main/skills/x/SKILL.md"
    end
  end

  describe "skills_in_tree/3" do
    test "a file link: the file's folder, with its other files" do
      tree =
        listing(
          [
            "README.md",
            "skills/pdf-forms/SKILL.md",
            "skills/pdf-forms/scripts/fill.py",
            "skills/pdf-forms/reference.md",
            "skills/other/SKILL.md"
          ],
          "skills/pdf-forms"
        )

      assert Source.skills_in_tree(tree, "skills/pdf-forms/SKILL.md", :file) ==
               {:ok,
                [
                  %{
                    path: "skills/pdf-forms",
                    file: "skills/pdf-forms/SKILL.md",
                    files: ["reference.md", "scripts/fill.py"]
                  }
                ], nil}
    end

    test "a file link at the root" do
      tree = tree(["SKILL.md", "LICENSE"])

      assert Source.skills_in_tree(tree, "SKILL.md", :file) ==
               {:ok, [%{path: "", file: "SKILL.md", files: ["LICENSE"]}], nil}
    end

    test "a folder with its own SKILL.md is that skill, nested ones and all" do
      tree =
        listing(
          [
            "skills/pdf-forms/SKILL.md",
            "skills/pdf-forms/extra/SKILL.md",
            "skills/pdf-forms/reference.md"
          ],
          "skills/pdf-forms"
        )

      assert Source.skills_in_tree(tree, "skills/pdf-forms", :folder) ==
               {:ok,
                [
                  %{
                    path: "skills/pdf-forms",
                    file: "skills/pdf-forms/SKILL.md",
                    files: ["extra/SKILL.md", "reference.md"]
                  }
                ], nil}
    end

    test "a folder of skills at two depths, by path, with nested ones skipped" do
      files = [
        "README.md",
        "skills/zeta/SKILL.md",
        "skills/alpha/SKILL.md",
        "skills/alpha/scripts/run.sh",
        "skills/alpha/inner/SKILL.md",
        "skills/.curated/linear/SKILL.md",
        "other/SKILL.md"
      ]

      assert {:ok, found, nil} =
               Source.skills_in_tree(listing(files, "skills"), "skills", :folder)

      assert Enum.map(found, & &1.path) == [
               "skills/.curated/linear",
               "skills/alpha",
               "skills/zeta"
             ]

      assert %{file: "skills/alpha/SKILL.md", files: ["inner/SKILL.md", "scripts/run.sh"]} =
               Enum.at(found, 1)

      # The repository's root finds every skill.
      assert {:ok, all, nil} = Source.skills_in_tree(listing(files, ""), "", :folder)
      assert length(all) == 4
    end

    test "a sibling whose name starts like another's isn't nested in it" do
      tree = listing(["s/a/SKILL.md", "s/a-b/SKILL.md", "s/a/b/SKILL.md"], "s")

      assert {:ok, found, nil} = Source.skills_in_tree(tree, "s", :folder)
      assert Enum.map(found, & &1.path) == ["s/a", "s/a-b"]
    end

    test "31 skills are cut to the first 30, with a notice" do
      files = for n <- 1..31, do: "skills/s#{String.pad_leading("#{n}", 2, "0")}/SKILL.md"

      assert {:ok, found, notice} =
               Source.skills_in_tree(listing(files, "skills"), "skills", :folder)

      assert length(found) == 30
      assert List.last(found).path == "skills/s30"

      assert notice ==
               "This folder has 31 skills; showing the first 30. " <>
                 "Link to a deeper folder for the rest."
    end

    test "no SKILL.md, a truncated tree and an unreadable answer are errors" do
      assert Source.skills_in_tree(tree(["README.md"]), "", :folder) ==
               {:error, "There's no SKILL.md in that folder."}

      assert Source.skills_in_tree(listing(["skills/x/SKILL.md"], "docs"), "docs", :folder) ==
               {:error, "There's no SKILL.md in that folder."}

      assert Source.skills_in_tree(tree(["x/SKILL.md"], true), "", :folder) ==
               {:error,
                "That repository is too big to list in one go. Link to the skill's folder " <>
                  "or its SKILL.md instead."}

      for {path, kind} <- [{"skills", :folder}, {"skills/x/SKILL.md", :file}] do
        assert Source.skills_in_tree(listing(["skills/x/SKILL.md"], "skills", true), path, kind) ==
                 {:error,
                  "That folder is too big to list in one go. Link to a folder deeper in it, " <>
                    "or to a skill's SKILL.md."}
      end

      assert {:error, _message} = Source.skills_in_tree(%{"message" => "Not Found"}, "", :folder)
    end
  end

  describe "saved/3" do
    defp pdf_candidate do
      folder = %{Source.pasted() | files: ["scripts/fill.py", "LICENSE"]}
      body = "Fill it with `scripts/fill.py`."
      text = "---\nname: PDF Forms\ndescription: d\nlicense: MIT\n---\n\n#{body}\n"
      Source.candidate("pasted", folder, {:ok, text})
    end

    test "says again the notes made for the candidate as it was" do
      candidate = pdf_candidate()

      assert Source.saved(candidate, candidate.name, candidate.instructions) == %{
               notes: candidate.notes,
               files_left_out: candidate.files_left_out
             }

      assert candidate.files_left_out == ["scripts/fill.py", "LICENSE"]
      assert Enum.any?(candidate.notes, &(&1 =~ "mention scripts/fill.py"))
    end

    test "follows a name and instructions the owner changed" do
      %{notes: notes, files_left_out: left_out} =
        Source.saved(pdf_candidate(), "pdf-filler", "Fill it by hand.")

      assert notes == [
               "Left out: scripts/fill.py, LICENSE. Photon skills are instructions only.",
               "Ignored front matter: license.",
               ~s(Renamed from "PDF Forms" to pdf-filler.)
             ]

      assert left_out == ["scripts/fill.py", "LICENSE"]
    end

    test "says nothing of a name kept as the SKILL.md had it" do
      text = "---\nname: pdf-forms\ndescription: d\n---\n\nDo it.\n"
      candidate = Source.candidate("pasted", Source.pasted(), {:ok, text})

      assert Source.saved(candidate, "pdf-forms", "Do it.").notes == []

      assert Source.saved(candidate, "pdf-filler", "Do it.").notes == [
               ~s(Renamed from "pdf-forms" to pdf-filler.)
             ]
    end

    test "keeps a candidate's own notes when it doesn't say what they came from" do
      assert Source.saved(%{origin: "pasted", notes: ["n"], files_left_out: ["f"]}, "x", "i") ==
               %{notes: ["n"], files_left_out: ["f"]}
    end
  end

  describe "notes/3" do
    test "left out files, ignored front matter, mentions and a rename, in that order" do
      folder = %{Source.pasted() | files: ["reference.md", "scripts/fill.py"]}
      parsed = %{name: "PDF Forms", description: "d", instructions: "i", ignored: ["license"]}

      assert Source.notes(folder, parsed, ["scripts/fill.py"]) == [
               "Left out: reference.md, scripts/fill.py. Photon skills are instructions only.",
               "Ignored front matter: license.",
               "The instructions mention scripts/fill.py, which wasn't installed.",
               ~s(Renamed from "PDF Forms" to pdf-forms: names use lowercase letters, ) <>
                 "digits and hyphens."
             ]
    end

    test "nothing to say says nothing; the folder's own notes come last" do
      parsed = %{name: "pdf-forms", description: "d", instructions: "i", ignored: []}
      assert Source.notes(Source.pasted(), parsed, []) == []

      folder = %{Source.pasted() | notes: ["Couldn't list the folder."]}

      assert Source.notes(folder, parsed, ["a.py", "b.sh"]) == [
               "The instructions mention a.py and b.sh, which weren't installed.",
               "Couldn't list the folder."
             ]
    end

    test "left out files are named up to 20, then counted" do
      files = for n <- 1..34, do: "f#{String.pad_leading("#{n}", 2, "0")}.md"
      folder = %{Source.pasted() | files: files}
      parsed = %{name: "x", description: "d", instructions: "i", ignored: []}

      assert [note] = Source.notes(folder, parsed, [])

      assert note ==
               "Left out: #{Enum.map_join(1..20, ", ", &"f#{String.pad_leading("#{&1}", 2, "0")}.md")}" <>
                 ", and 14 more. Photon skills are instructions only."
    end

    test "a rename says why: too long, or a name the app uses" do
      long = String.duplicate("a", 70)
      parsed = %{name: long, description: "d", instructions: "i", ignored: []}

      assert Source.notes(Source.pasted(), parsed, []) == [
               ~s(Renamed from "#{long}" to #{String.duplicate("a", 64)}: ) <>
                 "names are at most 64 characters."
             ]

      parsed = %{parsed | name: "new"}

      assert Source.notes(Source.pasted(), parsed, []) == [
               ~s(Renamed from "new" to new-skill: the app uses that name.)
             ]
    end
  end

  describe "candidate/3" do
    test "a fetched SKILL.md and its folder" do
      link = link("main", "skills", :folder)
      found = %{path: "skills/pdf-forms", file: "skills/pdf-forms/SKILL.md", files: ["LICENSE"]}

      text = """
      ---
      name: PDF Forms
      description: Fill in PDF forms.
      license: Apache-2.0
      ---

      # PDF forms
      """

      assert Source.candidate("fetched", Source.folder(link, found), {:ok, text}) == %{
               origin: "fetched",
               path: "skills/pdf-forms",
               source_url: "https://github.com/o/r/blob/main/skills/pdf-forms/SKILL.md",
               name: "pdf-forms",
               description: "Fill in PDF forms.",
               instructions: "# PDF forms",
               notes: [
                 "Left out: LICENSE. Photon skills are instructions only.",
                 "Ignored front matter: license.",
                 ~s(Renamed from "PDF Forms" to pdf-forms: names use lowercase letters, ) <>
                   "digits and hyphens."
               ],
               files_left_out: ["LICENSE"],
               error: nil,
               found: %{name: "PDF Forms", ignored: ["license"], files: ["LICENSE"], notes: []}
             }
    end

    test "files_left_out: mentions first, then the folder's files, deduplicated, at most 20" do
      files = ["LICENSE", "reference.md"] ++ for(n <- 1..25, do: "data/#{n}.csv") ++ ["z.py"]
      folder = %{Source.pasted() | files: files}
      body = "Run `z.py`, then read [the reference](reference.md)."

      candidate = Source.candidate("fetched", folder, {:ok, skill_md("x", body)})

      assert ["reference.md", "z.py", "LICENSE" | rest] = candidate.files_left_out
      assert length(rest) == 17
      assert hd(rest) == "data/1.csv"
    end

    test "a paste with a backticked scripts/fill.py gets that path" do
      body = "Fill the form with `python scripts/fill.py form.pdf`."

      candidate = Source.candidate("pasted", Source.pasted(), {:ok, skill_md("pdf-forms", body)})

      assert %{origin: "pasted", path: "", source_url: nil, error: nil} = candidate
      assert candidate.files_left_out == ["scripts/fill.py"]

      assert candidate.notes == [
               "The instructions mention scripts/fill.py, which wasn't installed."
             ]
    end

    test "a missing name or description stays nil" do
      text = "---\nlicense: MIT\n---\n\nDo it.\n"

      assert %{name: nil, description: nil, instructions: "Do it.", error: nil} =
               Source.candidate("pasted", Source.pasted(), {:ok, text})
    end

    test "a download error or a SKILL.md that doesn't parse is the candidate's error" do
      link = link("main", "skills", :folder)
      found = %{path: "skills/pdf-forms", file: "skills/pdf-forms/SKILL.md", files: []}
      folder = Source.folder(link, found)

      assert %{
               name: "pdf-forms",
               description: nil,
               instructions: nil,
               files_left_out: [],
               error: "Nothing at that address (404)."
             } = Source.candidate("fetched", folder, {:error, "Nothing at that address (404)."})

      assert %{error: "A SKILL.md starts with front matter" <> _} =
               Source.candidate("fetched", folder, {:ok, "# Just Markdown"})
    end
  end

  describe "result/2" do
    test "a single candidate that can't be installed is the error" do
      bad = Source.candidate("fetched", Source.web("https://x.test"), {:error, "Gone."})
      good = Source.candidate("fetched", Source.web("https://x.test"), {:ok, skill_md("a")})

      assert Source.result([bad], nil) == {:error, "Gone."}
      assert Source.result([good], nil) == {:ok, [good], nil}
      assert Source.result([good, bad], "Cut.") == {:ok, [good, bad], "Cut."}
    end
  end

  describe "text/2" do
    test "accepts text and refuses web pages and binaries" do
      assert Source.text("---\nname: x\n", ["text/plain; charset=utf-8"]) ==
               {:ok, "---\nname: x\n"}

      assert Source.text("anything", ["text/html; charset=utf-8"]) == {:error, :web_page}
      assert Source.text("\n  <!DOCTYPE html><html>", ["text/plain"]) == {:error, :web_page}
      assert Source.text("<HTML><body>", []) == {:error, :web_page}
      assert Source.text(<<0x89, "PNG", 0xFF, 0xFE>>, []) == {:error, :not_text}
      assert Source.text("a\0b", []) == {:error, :not_text}
    end
  end

  describe "error_message/2" do
    test "404 on GitHub and elsewhere" do
      assert Source.error_message(404, {:github, "github.com/o/r/blob/main/SKILL.md"}) ==
               "GitHub says there's nothing at github.com/o/r/blob/main/SKILL.md. If the " <>
                 "branch name has a slash in it, link to the SKILL.md's raw address instead."

      assert Source.error_message(404, {:api, "github.com/o/r"}) =~
               "GitHub says there's nothing at github.com/o/r."

      assert Source.error_message(404, :web) == "Nothing at that address (404)."
    end

    test "403 and 429 from the API are its limit" do
      for status <- [403, 429] do
        assert Source.error_message(status, {:api, "github.com/o/r"}) ==
                 "GitHub's limit for requests without a sign-in was reached. Try again " <>
                   "within the hour, or paste the SKILL.md."
      end

      assert Source.error_message(403, :web) == "The download failed: HTTP 403."
    end

    test "a timeout, a refused body and anything else" do
      assert Source.error_message(:timeout, :web) == "The download didn't finish in 15 seconds."

      assert Source.error_message(:too_big, :web) ==
               "That file is over 256 KB, too big for a skill."

      assert Source.error_message(:too_big, {:api, "github.com/o/r"}) =~ "too big to list"
      assert Source.error_message(:web_page, :web) =~ "That link is a web page, not a SKILL.md."
      assert Source.error_message(:not_text, :web) == "That file isn't text."
      assert Source.error_message(500, :web) == "The download failed: HTTP 500."

      assert Source.error_message("connection refused", :web) ==
               "The download failed: connection refused."
    end
  end
end
