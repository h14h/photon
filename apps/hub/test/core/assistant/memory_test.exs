defmodule Photon.Assistant.MemoryTest do
  @moduledoc "Editing the assistant's memory."

  use Photon.Case, async: true

  @doc_with_lines %{"text" => "- the NAS is mp1\n- prefers short answers"}

  test "add appends a dash line, without doubling a dash the text already has" do
    assert Memory.edit(Memory.empty(), "add", "  likes tea ") == %{"text" => "- likes tea"}

    assert Memory.edit(@doc_with_lines, "add", "- uses fish")["text"] ==
             "- the NAS is mp1\n- prefers short answers\n- uses fish"
  end

  test "remove drops every line containing the text" do
    assert Memory.edit(@doc_with_lines, "remove", "NAS") == %{"text" => "- prefers short answers"}
    assert Memory.edit(@doc_with_lines, "remove", "-") == %{"text" => ""}
  end

  test "rewrite replaces it all" do
    assert Memory.edit(@doc_with_lines, "rewrite", "  a\nb  ") == %{"text" => "a\nb"}
  end

  test "keeps the doc's other fields" do
    assert Memory.edit(%{"text" => "", "v" => 1}, "add", "x") == %{"text" => "- x", "v" => 1}
  end

  test "a replacement from the page is trimmed, and an empty memory reads (empty)" do
    assert Memory.replace("  hi \n") == %{"text" => "hi"}
    assert Memory.shown("") == "(empty)"
    assert Memory.shown("hi") == "hi"
  end
end
