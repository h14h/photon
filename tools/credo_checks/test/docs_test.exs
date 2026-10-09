defmodule PhotonCredo.DocsTest do
  use ExUnit.Case, async: true

  alias PhotonCredo.Docs

  @nothing %{defined: %{}, bare: MapSet.new()}

  @context %{
    resolve: &__MODULE__.resolve/1,
    file?: &__MODULE__.file?/1,
    anchors: &__MODULE__.anchors/1
  }

  @files [".", "docs", "docs/a.md", "docs/b.md", "apps/hub/mix.exs", "README.md"] ++
           ["apps/node/dist/notes.md"]

  def resolve("Photon.Gone"), do: {:error, "no module Photon.Gone"}
  def resolve(_name), do: :ok

  def file?(path), do: path in @files

  def anchors("docs/b.md"), do: ["hub-rules"]
  def anchors("apps/node/dist/notes.md"), do: :unavailable
  def anchors(_file), do: []

  describe "check/3" do
    test "reports names that don't resolve, with their line" do
      text = "fine: `Photon.Durable`\nnot: `Photon.Gone`, and `not a name`"

      assert Docs.check("docs/a.md", text, @context) == [
               {"docs/a.md", 2, "no module Photon.Gone"}
             ]
    end

    test "reports repo paths that don't exist, ignoring a line number" do
      text = "`apps/hub/mix.exs:12` and `apps/hub/gone.ex`; `tools/1` is a function"

      assert Docs.check("lib/x.ex", text, @context) == [
               {"lib/x.ex", 1, "no file apps/hub/gone.ex"}
             ]
    end

    test "checks names but not paths in test files, whose fixtures make paths up" do
      text = "`scripts/fill.py` and `Photon.Gone`"

      assert Docs.check("apps/hub/test/x_test.exs", text, @context) == [
               {"apps/hub/test/x_test.exs", 1, "no module Photon.Gone"}
             ]
    end

    test "checks Markdown links and their anchors, relative to the file" do
      text = """
      [ok](b.md#hub-rules) [up](../README.md) [web](https://example.com) [same](#nowhere)
      [gone](c.md) [anchor](b.md#node-rules)
      """

      assert Docs.check("docs/a.md", text, @context) == [
               {"docs/a.md", 1, "no heading for #nowhere in docs/a.md"},
               {"docs/a.md", 2, "broken link to docs/c.md"},
               {"docs/a.md", 2, "no heading for #node-rules in docs/b.md"}
             ]
    end

    test "reads links with titles, angle brackets, images and reference definitions" do
      text = """
      [t](gone.md "Title") [a](<gone2.md>) ![i](gone.png)
      [ref]: gone3.md
      """

      assert Docs.check("docs/a.md", text, @context) == [
               {"docs/a.md", 1, "broken link to docs/gone.md"},
               {"docs/a.md", 1, "broken link to docs/gone2.md"},
               {"docs/a.md", 1, "broken link to docs/gone.png"},
               {"docs/a.md", 2, "broken link to docs/gone3.md"}
             ]
    end

    test "follows links to directories" do
      assert Docs.check("docs/a.md", "[up](..) [here](.)", @context) == []
      assert Docs.check("README.md", "[root](.)", @context) == []
    end

    test "says when a generated file's anchors can't be read" do
      assert Docs.check("README.md", "[n](apps/node/dist/notes.md#usage)", @context) == [
               {"README.md", 1, "can't check #usage: apps/node/dist/notes.md isn't in the repo"}
             ]
    end

    test "leaves links in source files alone" do
      assert Docs.check("lib/x.ex", "[gone](c.md)", @context) == []
    end
  end

  test "anchors/1 slugs headings as GitHub does, outside code blocks" do
    text = """
    # Hub rules
    ## The `ops:2` capability
    ```
    # not a heading
    ```
    ~~~elixir
    # nor this
    ~~~
    Setext title
    ============

    Another one
    ---
    ## Hub rules ##
    """

    assert Docs.anchors(text) ==
             ["hub-rules", "the-ops2-capability", "setext-title", "another-one", "hub-rules-1"]
  end

  describe "resolve/2" do
    test "finds modules, functions with or without arity, types and callbacks" do
      for name <- [
            "PhotonCore.ID",
            "PhotonCore.ID.new",
            "PhotonCore.ID.new/1",
            "PhotonCore.Operation.t",
            "PhotonCore.LLM.Mock.respond/1"
          ] do
        assert Docs.resolve(name, @nothing) == :ok, name
      end
    end

    test "reports a missing module, function or arity" do
      assert Docs.resolve("PhotonCore.Gone", @nothing) == {:error, "no module PhotonCore.Gone"}
      assert Docs.resolve("PhotonCore.ID.gone", @nothing) == {:error, "no PhotonCore.ID.gone"}
      assert Docs.resolve("PhotonCore.ID.new/9", @nothing) == {:error, "no PhotonCore.ID.new/9"}
    end

    test "reads modules that aren't loaded here from their source" do
      known =
        Docs.known([
          """
          defmodule PhotonNode.TestLink do
            @type entry :: map()
            def snapshot(op), do: op
          end
          """,
          ~S'''
          defmodule Fake do
            @doc "defmodule PhotonCore.Phantom do"
          end
          ''',
          "children = [{Phoenix.PubSub, name: Photon.PubSub}]",
          "defmodule Broken do"
        ])

      assert Docs.resolve("PhotonNode.TestLink", known) == :ok
      assert Docs.resolve("PhotonNode.TestLink.snapshot/1", known) == :ok
      assert Docs.resolve("PhotonNode.TestLink.entry", known) == :ok
      assert Docs.resolve("PhotonNode", known) == :ok
      assert Docs.resolve("Photon.PubSub", known) == :ok

      assert Docs.resolve("PhotonNode.TestLink.gone/1", known) ==
               {:error, "no PhotonNode.TestLink.gone/1"}

      assert Docs.resolve("Photon.PubSub.broadcast/3", known) ==
               {:error, "no module Photon.PubSub"}

      assert Docs.resolve("PhotonCore.Phantom", known) ==
               {:error, "no module PhotonCore.Phantom"}

      assert Docs.resolve("Photon.Other", known) == {:error, "no module Photon.Other"}
    end
  end
end
