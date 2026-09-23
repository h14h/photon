defmodule Photon.Markdown do
  @moduledoc """
  CommonMark with GitHub-flavored tables, autolinks, strikethrough and task lists.

  Treat every message as untrusted: raw HTML is displayed as text and dangerous
  link schemes are blocked by Comrak. Never enable `unsafe` or HEEx rendering
  here, since model output must not become executable HTML or LiveView bindings.
  """

  def to_html(text) when is_binary(text) do
    MDEx.to_html!(text,
      extension: [table: true, autolink: true, strikethrough: true, tasklist: true],
      render: [unsafe: false, escape: true, tasklist_classes: true],
      syntax_highlight: nil
    )
  end
end
