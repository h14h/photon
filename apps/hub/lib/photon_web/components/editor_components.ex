defmodule PhotonWeb.EditorComponents do
  @moduledoc """
  The pieces the app's text editors share: the context file editor
  (`PhotonWeb.ContextFileLive`), the skill editor (`PhotonWeb.SkillLive`)
  and the install page's preview (`PhotonWeb.SkillInstallLive`).

    * `guarded_form/1` is a form that asks before the owner leaves it with
      unsaved text, through the colocated `.UnsavedGuard` hook. The hook
      lives here so both editors use the same one: a colocated hook's name
      belongs to the module whose template names it.
    * `markdown_editor/1` is a Markdown text field with `Write` and
      `Preview` tabs and a footer.
    * `editor_tab/1` is a `Write` or `Preview` tab in an editor's header.
    * `banner/1` is the notice above an editor when what it holds changed
      or went away elsewhere.
  """

  use Phoenix.Component

  import PhotonWeb.CoreComponents, only: [icon: 1, input: 1]

  alias Photon.Markdown

  @doc """
  A form that asks before the owner leaves with unsaved text: on closing
  or reloading the tab, and on following a live link (the sidebar, a
  back link). `dirty` is the server's view (rendered as `data-dirty`);
  typing since the form was last patched counts as unsaved too, since
  the server hears of it only after the text field's debounce. `leave`
  is the question the browser asks.

  Every other attribute (`phx-change`, `phx-submit`, `class`) goes to the
  `<.form>`.
  """
  attr :for, :any, required: true, doc: "the form, from `to_form/2`"
  attr :id, :string, required: true
  attr :dirty, :boolean, required: true
  attr :leave, :string, required: true, doc: "the question asked before leaving"
  attr :rest, :global
  slot :inner_block, required: true

  @spec guarded_form(map()) :: Phoenix.LiveView.Rendered.t()
  def guarded_form(assigns) do
    ~H"""
    <.form
      for={@for}
      id={@id}
      phx-hook=".UnsavedGuard"
      data-dirty={to_string(@dirty)}
      data-leave={@leave}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.form>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".UnsavedGuard">
      // Asks before leaving the editor with unsaved text: closing or
      // reloading the tab (beforeunload), and following a live link (the
      // sidebar, the back link), which LiveView handles without unloading.
      // The server's data-dirty lags typing by the content's debounce, so
      // typing since the last patch of the form counts as unsaved too.
      export default {
        mounted() {
          this.typed = false
          this.onInput = () => { this.typed = true }
          this.el.addEventListener("input", this.onInput)

          this.onUnload = e => {
            if (!this.dirty()) return
            e.preventDefault()
            e.returnValue = ""
          }
          window.addEventListener("beforeunload", this.onUnload)

          // In the capture phase, so it runs before LiveView's own handler
          // on window; stopping the event there keeps the page.
          this.onClick = e => {
            const link = e.target.closest?.("a[data-phx-link]")
            if (!link || !this.dirty()) return
            if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return
            if (confirm(this.el.dataset.leave)) return
            e.preventDefault()
            e.stopPropagation()
          }
          document.addEventListener("click", this.onClick, true)
        },

        updated() { this.typed = false },

        destroyed() {
          window.removeEventListener("beforeunload", this.onUnload)
          document.removeEventListener("click", this.onClick, true)
        },

        dirty() { return this.typed || this.el.dataset.dirty === "true" }
      }
    </script>
    """
  end

  @doc """
  A Markdown text field with `Write` and `Preview` tabs, and a footer.
  The tabs send `tab` (see `editor_tab/1`); `tab` is the open one. On
  `Preview` the text field stays in the form, hidden, so the text is
  still sent and kept, and the field's text shows rendered (or "Nothing
  to preview yet.").

  The footer slot is the card's last row: what the editor holds, and the
  submit button. Every other attribute (`placeholder`, `aria-label`) goes
  to the text field.
  """
  attr :id, :string,
    required: true,
    doc: "the tabs' IDs are `<id>-tab-write` and `<id>-tab-preview`"

  attr :field, Phoenix.HTML.FormField, required: true
  attr :tab, :string, required: true
  attr :input_id, :string, required: true
  attr :editor_id, :string, default: nil, doc: "the text field's wrapper's ID, if any"
  attr :preview_id, :string, required: true
  attr :rows, :string, required: true
  attr :min_height, :string, required: true, doc: "the text's and the preview's `min-h-*` class"
  attr :rest, :global, include: ~w(placeholder)
  slot :footer, required: true

  @spec markdown_editor(map()) :: Phoenix.LiveView.Rendered.t()
  def markdown_editor(assigns) do
    assigns = assign(assigns, :text, assigns.field.value || "")

    ~H"""
    <div class="overflow-hidden rounded-2xl border border-line bg-surface shadow-xs transition focus-within:border-accent/60 focus-within:shadow-md focus-within:shadow-accent/10">
      <div class="flex items-center justify-between gap-3 border-b border-line bg-sunken/50 px-3 py-2">
        <div role="tablist" class="flex items-center rounded-full border border-line bg-sunken p-0.5">
          <.editor_tab id={"#{@id}-tab-write"} tab="write" current={@tab}>Write</.editor_tab>
          <.editor_tab id={"#{@id}-tab-preview"} tab="preview" current={@tab}>
            Preview
          </.editor_tab>
        </div>
        <span class="flex items-center gap-1.5 text-[11.5px] text-ink-faint">
          <.icon name="hero-document-text-micro" class="size-4" /> Markdown
        </span>
      </div>

      <div id={@editor_id} class={["px-4 pt-3 pb-3", @tab == "preview" && "hidden"]}>
        <.input
          field={@field}
          id={@input_id}
          type="textarea"
          rows={@rows}
          phx-debounce="400"
          spellcheck="false"
          class={[
            "block",
            @min_height,
            "w-full resize-y bg-transparent font-mono text-[13px] leading-relaxed text-ink outline-none placeholder:text-ink-faint"
          ]}
          {@rest}
        />
      </div>

      <div
        :if={@tab == "preview"}
        id={@preview_id}
        class={["markdown-body", @min_height, "px-5 py-4 text-ink-soft"]}
      >
        <%= if String.trim(@text) == "" do %>
          <p class="text-[14px] text-ink-faint">Nothing to preview yet.</p>
        <% else %>
          {Phoenix.HTML.raw(Markdown.to_html(@text))}
        <% end %>
      </div>

      <div class="flex items-center justify-between gap-3 border-t border-line px-4 py-3">
        {render_slot(@footer)}
      </div>
    </div>
    """
  end

  @doc """
  A tab in an editor's header, `Write` or `Preview`. Clicking it sends
  `tab` with `tab` as its value; the page keeps which one is open.
  """
  attr :id, :string, required: true
  attr :tab, :string, required: true
  attr :current, :string, required: true
  slot :inner_block, required: true

  @spec editor_tab(map()) :: Phoenix.LiveView.Rendered.t()
  def editor_tab(assigns) do
    ~H"""
    <button
      type="button"
      role="tab"
      id={@id}
      aria-selected={to_string(@tab == @current)}
      phx-click="tab"
      phx-value-tab={@tab}
      class={[
        "rounded-full px-3 py-0.5 text-[12.5px] transition",
        @tab == @current && "bg-surface font-medium text-ink shadow-xs",
        @tab != @current && "text-ink-faint hover:text-ink"
      ]}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc "A notice above an editor: `warn` for a change elsewhere, `bad` for a delete."
  attr :id, :string, required: true
  attr :tone, :string, values: ~w(warn bad), required: true
  attr :icon, :string, required: true
  slot :inner_block, required: true
  slot :actions

  @spec banner(map()) :: Phoenix.LiveView.Rendered.t()
  def banner(assigns) do
    ~H"""
    <div
      id={@id}
      role="status"
      class={[
        "mt-5 flex flex-wrap items-center gap-x-4 gap-y-3 rounded-xl border px-4 py-3",
        @tone == "warn" && "border-warn/30 bg-warn-soft",
        @tone == "bad" && "border-bad/30 bg-bad-soft"
      ]}
    >
      <p class="flex min-w-0 flex-1 items-center gap-2.5 text-[13.5px] text-ink">
        <.icon
          name={@icon}
          class={["size-4 shrink-0", @tone == "warn" && "text-warn", @tone == "bad" && "text-bad"]}
        />
        {render_slot(@inner_block)}
      </p>
      <div :if={@actions != []} class="flex items-center gap-2">{render_slot(@actions)}</div>
    </div>
    """
  end
end
