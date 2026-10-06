defmodule Photon.Skills.SkillMdTest do
  @moduledoc "Reading a SKILL.md (section 2.3 of the step 3 plan)."

  use Photon.Case, async: true

  alias Photon.Skills.SkillMd

  @fixtures Path.expand("../../support/fixtures/skills", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  test "reads a plain file" do
    text = """
    ---
    name: pdf-forms
    description: Fill in PDF forms. Use when the user asks to fill or flatten a PDF form.
    license: Apache-2.0
    allowed-tools: Bash(python:*)
    ---

    # PDF forms

    Fill the form.
    """

    assert SkillMd.parse(text) ==
             {:ok,
              %{
                name: "pdf-forms",
                description:
                  "Fill in PDF forms. Use when the user asks to fill or flatten a PDF form.",
                instructions: "# PDF forms\n\nFill the form.",
                ignored: ["license", "allowed-tools"]
              }}
  end

  test "accepts a byte order mark and \\r\\n line ends" do
    text = "﻿---\r\nname: pdf-forms\r\ndescription: Fill forms.\r\n---\r\n# PDF\r\n\r\nStep.\r\n"

    assert {:ok, %{name: "pdf-forms", description: "Fill forms.", instructions: "# PDF\n\nStep."}} =
             SkillMd.parse(text)
  end

  test "reads quoted values with their escapes" do
    text = ~S"""
    ---
    name: 'it''s-a-name'
    description: "Say \"hi\", use a \\ and\na new line. \t Tabbed." # a comment
    ---
    Body
    """

    assert {:ok, %{name: "it's-a-name", description: description}} = SkillMd.parse(text)
    assert description == "Say \"hi\", use a \\ and\na new line. \t Tabbed."
  end

  test "reads the escapes that name a code point, and keeps one that doesn't as written" do
    text = ~S"""
    ---
    name: x
    description: "Caf\u00e9, \xe9t\xE9, \U0001F600; \u12 \uD800 \U00110000 \xzz."
    ---
    Body
    """

    assert {:ok, %{description: description}} = SkillMd.parse(text)
    assert description == "Café, été, 😀; \\u12 \\uD800 \\U00110000 \\xzz."
  end

  test "folds a quoted value over indented lines" do
    text = """
    ---
    name: x
    description: "Fill in PDF forms.
      Use when asked."
    ---
    Body
    """

    assert {:ok, %{description: "Fill in PDF forms. Use when asked."}} = SkillMd.parse(text)
  end

  test "reads block scalars" do
    text = """
    ---
    name: x
    literal: |
      one
      two
    description: >-
      Fill in PDF forms.
      Use when asked.

      Second paragraph.
    keep: |-
      kept
    folded: >
      a
      b
    ---
    Body
    """

    assert {:ok, %{description: "Fill in PDF forms. Use when asked.\nSecond paragraph."} = md} =
             SkillMd.parse(text)

    assert md.ignored == ["literal", "keep", "folded"]

    literal = "---\nname: x\ndescription: |\n  one\n  two\n\n  three\n---\nBody\n"
    assert {:ok, %{description: "one\ntwo\n\nthree"}} = SkillMd.parse(literal)

    keep = "---\nname: x\ndescription: |-\n    deep\n      deeper\n---\nBody\n"
    assert {:ok, %{description: "deep\n  deeper"}} = SkillMd.parse(keep)
  end

  test "folds a plain value over indented lines" do
    text = """
    ---
    name: pdf-forms
    description: Fill in PDF forms.
      Use when the user asks
      to fill one. # not part of it
    ---
    Body
    """

    assert {:ok, %{description: "Fill in PDF forms. Use when the user asks to fill one."}} =
             SkillMd.parse(text)
  end

  test "skips a nested block whole and lists its key as ignored" do
    text = """
    ---
    name: pdf-forms
    metadata:
      short-description: Forms
      tags:
        - pdf
    allowed-tools:
    - Bash
    - Read
    description: Fill in PDF forms.
    ---
    Body
    """

    assert {:ok, %{name: "pdf-forms", description: "Fill in PDF forms.", ignored: ignored}} =
             SkillMd.parse(text)

    assert ignored == ["metadata", "allowed-tools"]
  end

  test "skips comments and blank lines" do
    text = """
    ---
    # Who wrote it
    name: pdf-forms

    # When to use it
    description: Fill forms.
    ---
    Body
    """

    assert {:ok, %{name: "pdf-forms", description: "Fill forms.", ignored: []}} =
             SkillMd.parse(text)
  end

  test "a missing name or description is nil, not an error" do
    assert {:ok, %{name: nil, description: nil, ignored: ["license"]}} =
             SkillMd.parse("---\nlicense: MIT\n---\nBody\n")

    assert {:ok, %{name: nil, description: "d"}} =
             SkillMd.parse("---\nname:\ndescription: d\n---\nBody\n")

    assert {:ok, %{name: nil}} = SkillMd.parse("---\nname: \"\"\ndescription: d\n---\nBody\n")
  end

  test "refuses text with no front matter" do
    assert SkillMd.parse("# PDF forms\n\nFill it.") ==
             {:error,
              "A SKILL.md starts with front matter: a line with three dashes (---), " <>
                "then name: and description: lines, then another ---."}

    assert {:error, "A SKILL.md starts" <> _} = SkillMd.parse("")
  end

  test "refuses front matter that never ends" do
    assert SkillMd.parse("---\nname: x\ndescription: y\n# Body\n") ==
             {:error, "The front matter never ends: add a line with three dashes (---) after it."}
  end

  test "refuses an empty body" do
    assert SkillMd.parse("---\nname: x\ndescription: y\n---\n\n  \n") ==
             {:error, "This SKILL.md has no instructions after its front matter."}
  end

  test "keeps a --- line in the body" do
    assert {:ok, %{instructions: "One\n\n---\n\nTwo"}} =
             SkillMd.parse("---\nname: x\ndescription: y\n---\nOne\n\n---\n\nTwo\n")
  end

  describe "real SKILL.md files" do
    test "anthropics/skills webapp-testing" do
      text = fixture("anthropics-webapp-testing.SKILL.md")

      assert {:ok, md} = SkillMd.parse(text)
      assert md.name == "webapp-testing"
      assert md.description =~ ~r/\AToolkit for interacting with and testing local web/
      assert md.description =~ ~r/viewing browser logs\.\z/
      assert md.ignored == ["license"]
      assert md.instructions =~ ~r/\A# Web Application Testing/
      assert md.instructions =~ "scripts/with_server.py"
    end

    test "openai/skills linear" do
      text = fixture("openai-linear.SKILL.md")

      assert {:ok, md} = SkillMd.parse(text)
      assert md.name == "linear"

      assert md.description ==
               "Manage issues, projects & team workflows in Linear. Use when the user wants " <>
                 "to read, create or updates tickets in Linear."

      assert md.ignored == ["metadata"]
      assert md.instructions =~ ~r/\A# Linear\n/
    end
  end
end
