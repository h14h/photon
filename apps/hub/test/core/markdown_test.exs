defmodule Photon.MarkdownTest do
  @moduledoc "Streaming text, shown a finished block at a time."

  use Photon.Case, async: true

  alias Photon.Markdown

  describe "settled text" do
    test "is nothing until a block is finished" do
      assert Markdown.settled("Hello wor") == ""
      assert Markdown.settled("Hello world.\n") == ""
    end

    test "ends at a blank line" do
      assert Markdown.settled("Para one.\n\nPara tw") == "Para one.\n\n"
      assert Markdown.settled("Para.  \r\n\r\nNext") == "Para.  \r\n\r\n"
      assert Markdown.settled("Héllo wörld.\n\nnext") == "Héllo wörld.\n\n"
    end

    test "ends where a list item starts, once its marker is whole" do
      assert Markdown.settled("Intro:\n- one\n- tw") == "Intro:\n- one\n"
      assert Markdown.settled("Intro:\n1. one\n2) tw") == "Intro:\n1. one\n"
      assert Markdown.settled("Intro:\n- one\n-") == "Intro:\n"
      assert Markdown.settled("Intro:\n- one\n- ") == "Intro:\n"
    end

    test "holds a section title until content follows it" do
      assert Markdown.settled("## Title\n\nBody so far") == ""
      assert Markdown.settled("**Bold title**\n\nstill coming") == ""
      assert Markdown.settled("## Title\nBody line\n\nmore") == "## Title\nBody line\n\n"
    end

    test "ends above an unindented heading, even without a blank line" do
      assert Markdown.settled("Para.\n# Heading\nmore") == "Para.\n"
    end

    test "keeps a code block whole: nothing inside it ends a block" do
      open = "Text\n\n```elixir\nIO.puts 1\n\n- x = 2\n"
      assert Markdown.settled(open) == "Text\n\n"

      closed = "Text\n\n```elixir\nIO.puts 1\n```\nafter"
      assert Markdown.settled(closed) == "Text\n\n```elixir\nIO.puts 1\n```\n"
    end

    test "closes a fence only with the same character, as long, with no info string" do
      assert Markdown.settled("```\ncode\n~~~\nmore\n") == ""
      assert Markdown.settled("````\ncode\n```\nmore\n") == ""
      assert Markdown.settled("```\ncode\n``` js\nmore\n") == ""
      assert Markdown.settled("~~~\ncode\n~~~~\nmore") == "~~~\ncode\n~~~~\n"
    end
  end
end
