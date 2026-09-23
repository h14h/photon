defmodule PhotonWeb.TranscriptComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  alias PhotonWeb.TranscriptComponents

  defp document(text) do
    render_component(&TranscriptComponents.markdown/1, text: text)
    |> LazyHTML.from_fragment()
  end

  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  test "renders GFM tables, alignment and inline formatting" do
    doc = document("| Feature | Status |\n| :--- | ---: |\n| **Tables** | `ready` |")
    assert count(doc, ".markdown-body table thead th") == 2
    assert count(doc, "tbody td strong") == 1
    assert count(doc, "tbody td[align=right] code") == 1
  end

  test "renders CommonMark blocks and GFM extensions" do
    doc =
      document("""
      # Heading

      ## Subheading

      > A *quote* with ~~old~~ text.

      1. First
         - Nested
      2. Second

      - [x] Done
      - [ ] Pending

      [Link](https://example.com) and https://example.org

      ![Example](https://example.com/image.png)

      ---

      ```elixir
      IO.puts("<hello>")
      ```
      """)

    for selector <- [
          "h1",
          "h2",
          "blockquote em",
          "blockquote del",
          "ol li ul li",
          "input[checked][disabled]",
          "input:not([checked])[disabled]",
          "a[href='https://example.com']",
          "a[href='https://example.org']",
          "img[alt=Example]",
          "hr",
          "pre code.language-elixir"
        ] do
      assert count(doc, selector) == 1, "missing #{selector}"
    end

    assert doc |> LazyHTML.query("pre code") |> LazyHTML.text() == "IO.puts(\"<hello>\")\n"
  end

  test "untrusted HTML and LiveView attributes never become active markup" do
    doc =
      document("""
      <script>alert(1)</script>

      <img src=x onerror="alert(1)">

      <button phx-click="delete_session">delete</button>

      <svg onload="alert(1)"></svg>

      [bad](javascript:alert%281%29)
      [encoded](jav&#x61;script:alert%281%29)
      [data](data:text/html;base64,PHNjcmlwdD4=)
      ![bad](javascript:alert%281%29)
      """)

    assert count(doc, "script, svg, button, [onerror], [onload], [phx-click]") == 0
    assert count(doc, "[href^='javascript:'], [href^='data:'], [src^='javascript:']") == 0
    assert LazyHTML.text(doc) =~ "<script>alert(1)</script>"
  end

  test "handles empty text and unfinished Markdown without crashing" do
    assert count(document(""), ".markdown-body") == 1
    assert count(document("```elixir\n<incomplete>"), "pre code") == 1
    assert LazyHTML.text(document("unfinished **bold")) =~ "unfinished **bold"
  end

  test "user messages remain literal" do
    doc =
      render_component(&TranscriptComponents.entry/1,
        entry: %{type: :user, text: "**literal** <script>alert(1)</script>"}
      )
      |> LazyHTML.from_fragment()

    assert count(doc, "strong, script, .markdown-body") == 0
    assert LazyHTML.text(doc) =~ "**literal** <script>alert(1)</script>"
  end
end
