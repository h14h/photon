defmodule Photon.SkillsFetchTest do
  @moduledoc """
  `Photon.Skills.fetch/1` against a `Req.Test` stub standing in for GitHub
  and other sites (`config/test.exs` points `Photon.Skills` at it). The
  rules for links, trees, notes and messages are covered in
  `test/core/skills/source_test.exs`; these check the requests made and
  what comes back.
  """

  # Stubs belong to the test process (and the tasks it starts), so tests
  # can run side by side; nothing here touches the database.
  use ExUnit.Case, async: true

  alias Photon.Skills

  @pdf_forms """
  ---
  name: pdf-forms
  description: Fill in PDF forms. Use when the user asks to fill or flatten a PDF form.
  license: Apache-2.0
  ---

  # PDF forms

  Run `scripts/fill.py` with the form.
  """

  defp skill_md(name),
    do: "---\nname: #{name}\ndescription: Use for #{name}.\n---\n\nDo #{name}.\n"

  defp tree(files, truncated \\ false) do
    %{
      "sha" => "abc",
      "tree" => Enum.map(files, &%{"path" => &1, "type" => "blob", "mode" => "100644"}),
      "truncated" => truncated
    }
  end

  # Answers each request with `answers`' function for "host/path" (a
  # missing one is a 404), and tells the test what was asked, in order.
  defp stub(answers) do
    test = self()

    Req.Test.stub(Skills, fn conn ->
      at = conn.host <> conn.request_path
      send(test, {:asked, at})

      case Map.fetch(answers, at) do
        {:ok, answer} -> answer.(conn)
        :error -> Plug.Conn.send_resp(conn, 404, "Not Found")
      end
    end)
  end

  defp json(value), do: &Req.Test.json(&1, value)
  defp text(value), do: &Req.Test.text(&1, value)
  defp status(code, body \\ ""), do: &Plug.Conn.send_resp(&1, code, body)

  defp asked do
    receive do
      {:asked, at} -> [at | asked()]
    after
      0 -> []
    end
  end

  @tree_main "api.github.com/repos/o/r/git/trees/main"
  @raw_main "raw.githubusercontent.com/o/r/main/"

  describe "a GitHub link" do
    test "to a SKILL.md: one tree call, one download, the rest of the folder left out" do
      stub(%{
        @tree_main =>
          json(
            tree([
              "README.md",
              "skills/pdf-forms/SKILL.md",
              "skills/pdf-forms/scripts/fill.py",
              "skills/pdf-forms/reference.md",
              "skills/other/SKILL.md"
            ])
          ),
        (@raw_main <> "skills/pdf-forms/SKILL.md") => text(@pdf_forms)
      })

      assert {:ok, [candidate], nil} =
               Skills.fetch("https://github.com/o/r/blob/main/skills/pdf-forms/SKILL.md")

      assert asked() == [@tree_main, @raw_main <> "skills/pdf-forms/SKILL.md"]

      assert candidate == %{
               origin: "fetched",
               path: "skills/pdf-forms",
               source_url: "https://github.com/o/r/blob/main/skills/pdf-forms/SKILL.md",
               name: "pdf-forms",
               description:
                 "Fill in PDF forms. Use when the user asks to fill or flatten a PDF form.",
               instructions: "# PDF forms\n\nRun `scripts/fill.py` with the form.",
               notes: [
                 "Left out: reference.md, scripts/fill.py. Photon skills are instructions only.",
                 "Ignored front matter: license.",
                 "The instructions mention scripts/fill.py, which wasn't installed."
               ],
               files_left_out: ["scripts/fill.py", "reference.md"],
               error: nil
             }
    end

    test "to a skill's folder downloads its SKILL.md" do
      stub(%{
        @tree_main => json(tree(["skills/pdf-forms/SKILL.md", "skills/pdf-forms/LICENSE"])),
        (@raw_main <> "skills/pdf-forms/SKILL.md") => text(@pdf_forms)
      })

      # With the folder listed, only files in it count as left out: the
      # scripts/fill.py the instructions name isn't there.
      assert {:ok, [%{name: "pdf-forms", files_left_out: ["LICENSE"]}], nil} =
               Skills.fetch("https://github.com/o/r/tree/main/skills/pdf-forms")

      assert asked() == [@tree_main, @raw_main <> "skills/pdf-forms/SKILL.md"]
    end

    test "to a repository's root asks for its default branch first" do
      stub(%{
        "api.github.com/repos/o/r" => json(%{"default_branch" => "trunk"}),
        "api.github.com/repos/o/r/git/trees/trunk" => json(tree(["SKILL.md"])),
        "raw.githubusercontent.com/o/r/trunk/SKILL.md" => text(skill_md("root-skill"))
      })

      assert {:ok, [%{name: "root-skill", path: "", source_url: source_url}], nil} =
               Skills.fetch("https://github.com/o/r.git")

      assert source_url == "https://github.com/o/r/blob/trunk/SKILL.md"

      assert asked() == [
               "api.github.com/repos/o/r",
               "api.github.com/repos/o/r/git/trees/trunk",
               "raw.githubusercontent.com/o/r/trunk/SKILL.md"
             ]
    end

    test "to a folder of skills offers each, and one whose download fails keeps its error" do
      stub(%{
        @tree_main =>
          json(tree(["skills/a/SKILL.md", "skills/b/SKILL.md", "skills/c/SKILL.md", "x.md"])),
        (@raw_main <> "skills/a/SKILL.md") => text(skill_md("a")),
        (@raw_main <> "skills/b/SKILL.md") => status(500),
        (@raw_main <> "skills/c/SKILL.md") => text(skill_md("c"))
      })

      assert {:ok, [a, b, c], nil} = Skills.fetch("https://github.com/o/r/tree/main/skills")

      assert %{name: "a", instructions: "Do a.", error: nil} = a
      assert %{name: "b", instructions: nil, error: "The download failed: HTTP 500."} = b
      assert %{name: "c", instructions: "Do c.", error: nil} = c

      assert [@tree_main | downloads] = asked()
      assert length(downloads) == 3
    end

    test "to a folder of more than 30 skills offers 30 with a notice" do
      files = for n <- 1..32, do: "s/#{String.pad_leading("#{n}", 2, "0")}/SKILL.md"

      answers =
        Map.new(files, fn file ->
          {@raw_main <> file, text(skill_md("s" <> String.slice(file, 2, 2)))}
        end)

      stub(Map.put(answers, @tree_main, json(tree(files))))

      assert {:ok, candidates, "This folder has 32 skills; showing the first 30." <> _} =
               Skills.fetch("https://github.com/o/r/tree/main/s")

      assert length(candidates) == 30
      assert Enum.all?(candidates, &is_nil(&1.error))
    end

    test "a tree call that fails on a file link still downloads the file, with a note" do
      stub(%{
        @tree_main => status(403, ~s({"message": "API rate limit exceeded"})),
        (@raw_main <> "skills/pdf-forms/SKILL.md") => text(@pdf_forms)
      })

      assert {:ok, [candidate], nil} =
               Skills.fetch("https://github.com/o/r/blob/main/skills/pdf-forms/SKILL.md")

      assert %{path: "skills/pdf-forms", name: "pdf-forms", error: nil} = candidate
      assert candidate.files_left_out == ["scripts/fill.py"]

      assert List.last(candidate.notes) ==
               "Couldn't list the folder on GitHub, so other files it may have weren't checked."
    end

    test "a 403 from the API on a folder link is its limit" do
      stub(%{@tree_main => status(403, ~s({"message": "API rate limit exceeded"}))})

      assert Skills.fetch("https://github.com/o/r/tree/main/skills") ==
               {:error,
                "GitHub's limit for requests without a sign-in was reached. Try again within " <>
                  "the hour, or paste the SKILL.md."}
    end

    test "a 404 says where and what to do" do
      stub(%{@tree_main => json(tree(["skills/x/SKILL.md"]))})

      assert Skills.fetch("https://github.com/o/r/blob/main/skills/x/SKILL.md") ==
               {:error,
                "GitHub says there's nothing at github.com/o/r/blob/main/skills/x/SKILL.md. " <>
                  "If the branch name has a slash in it, link to the SKILL.md's raw address " <>
                  "instead."}

      stub(%{})

      assert {:error, "GitHub says there's nothing at github.com/o/r/tree/feature/x." <> _} =
               Skills.fetch("https://github.com/o/r/tree/feature/x")
    end

    test "a folder without a SKILL.md, and a truncated tree" do
      stub(%{@tree_main => json(tree(["README.md"]))})

      assert Skills.fetch("https://github.com/o/r/tree/main") ==
               {:error, "There's no SKILL.md in that folder."}

      stub(%{@tree_main => json(tree(["a/SKILL.md"], true))})

      assert {:error, "That repository is too big to list in one go." <> _} =
               Skills.fetch("https://github.com/o/r/tree/main")
    end
  end

  describe "any other link" do
    test "is downloaded as a file" do
      stub(%{"example.com/skills/SKILL.md" => text(skill_md("notes"))})

      assert {:ok, [candidate], nil} = Skills.fetch("https://example.com/skills/SKILL.md")

      assert %{
               origin: "fetched",
               path: "",
               source_url: "https://example.com/skills/SKILL.md",
               name: "notes",
               notes: [],
               files_left_out: [],
               error: nil
             } = candidate

      assert asked() == ["example.com/skills/SKILL.md"]
    end

    test "follows a redirect" do
      stub(%{
        "example.com/old" => fn conn ->
          conn
          |> Plug.Conn.put_resp_header("location", "https://example.com/new")
          |> Plug.Conn.send_resp(302, "")
        end,
        "example.com/new" => text(skill_md("moved"))
      })

      assert {:ok, [%{name: "moved"}], nil} = Skills.fetch("https://example.com/old")
    end

    test "a web page, a file over 256 KB and a binary are refused" do
      stub(%{"example.com/page" => &Req.Test.html(&1, "<!DOCTYPE html><html></html>")})

      assert Skills.fetch("https://example.com/page") ==
               {:error,
                "That link is a web page, not a SKILL.md. Link to the file on GitHub, or to " <>
                  "its raw address."}

      big = skill_md("big") <> String.duplicate("x", 300 * 1024)
      stub(%{"example.com/big" => text(big)})

      assert Skills.fetch("https://example.com/big") ==
               {:error, "That file is over 256 KB, too big for a skill."}

      stub(%{"example.com/image.png" => status(200, <<0x89, "PNG\r\n", 0x1A, 0xFF, 0xD8>>)})

      assert Skills.fetch("https://example.com/image.png") == {:error, "That file isn't text."}
    end

    test "a 404 and a timeout say what happened" do
      stub(%{})

      assert Skills.fetch("https://example.com/gone") ==
               {:error, "Nothing at that address (404)."}

      stub(%{"example.com/slow" => &Req.Test.transport_error(&1, :timeout)})

      assert Skills.fetch("https://example.com/slow") ==
               {:error, "The download didn't finish in 15 seconds."}
    end

    test "a link that isn't http or https asks for one, without a request" do
      stub(%{})

      assert Skills.fetch("ftp://example.com/SKILL.md") ==
               {:error, "Give an https:// link to a SKILL.md, or to a folder on GitHub."}

      assert asked() == []
    end
  end
end
