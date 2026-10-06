defmodule PhotonWeb.ContextFileLive do
  @moduledoc """
  A project's context file (section 5.5 of
  `docs/plans/step-2-projects-and-threads.md`): `:new` at
  `/projects/:slug/files/new` makes one, `:edit` at
  `/projects/:slug/files/:name` shows and edits one.

  The editor is a form over a plain map (`name`, `content` and, when
  editing, the hidden `version` it loaded), with `Write` and `Preview`
  tabs. Saving hands the text to `Photon.Projects`, which checks it and the
  version; its errors show under their fields.

  Threads in the project write the same files, so the page listens on
  `Projects.subscribe_files/1` for the open file:

    * a clean editor loads the new version
    * a dirty one keeps the user's text and shows `#file-changed`, with
      `Load the new version` (discards the text) and `Keep my text` (takes
      the new version's number, so the next save writes over it)
    * a deleted file shows `#file-deleted`; saving creates it again

  A save with an old version (`:stale`) shows the same banner and keeps the
  text in the box. When the text is replaced from the server, the editor
  gets a new DOM ID (`@revision`), because LiveView leaves a focused
  textarea's value alone and the user would otherwise see, and save over,
  the old text.

  `{:projects_changed, id}` comes through `PhotonWeb.Shell` and keeps the
  project's name current. A `:tick` once a minute redraws `#file-meta`, so
  "changed just now" ages on a page left open. An unknown project or file goes back to `/`
  with a flash.
  """

  use PhotonWeb, :live_view

  alias Photon.{Markdown, Projects, Threads}
  alias Photon.Projects.{ContextFile, Project}
  alias PhotonWeb.ProjectText

  @tick_ms :timer.minutes(1)

  @impl true
  def mount(%{"slug" => slug} = params, _session, socket) do
    with {:ok, project} <- project(slug),
         {:ok, file} <- file(project, params, socket.assigns.live_action) do
      if file && connected?(socket) do
        :ok = Projects.subscribe_files(project.id)
        tick()
      end

      {:ok,
       socket
       |> assign(project: project, tab: "write", revision: 0)
       |> assign(page_title: title(project, file))
       |> load(file)}
    else
      {:error, message} -> {:ok, gone(socket, message)}
    end
  end

  defp project(slug) do
    case Projects.get_by_slug(slug) do
      %Project{} = project -> {:ok, project}
      nil -> {:error, "There's no project called #{slug}."}
    end
  end

  defp file(_project, _params, :new), do: {:ok, nil}

  defp file(project, %{"name" => name}, :edit) do
    case Projects.get_file(project.id, name) do
      %ContextFile{} = file -> {:ok, file}
      nil -> {:error, "There's no file called #{name} in #{project.name}."}
    end
  end

  defp title(project, nil), do: "New file in #{project.name}"
  defp title(project, file), do: "#{file.name} in #{project.name}"

  defp gone(socket, message), do: socket |> put_flash(:error, message) |> push_navigate(to: ~p"/")

  # The meta line says how long ago the file changed, so it is redrawn once a minute.
  defp tick do
    # Never cancelled: it fires once and the next is set then; it dies with the page.
    _timer = Process.send_after(self(), :tick, @tick_ms)
    :ok
  end

  ## The editor's state

  # Opens `file` (nil for a new one) in a clean editor.
  defp load(socket, nil) do
    form = file_form(%{"name" => "", "content" => ""})
    assign(socket, file: nil, form: form, dirty?: false, conflict: nil, meta: nil)
  end

  defp load(socket, %ContextFile{} = file) do
    params = %{"content" => file.content, "version" => Integer.to_string(file.version)}

    socket
    |> assign(file: file, form: file_form(params), dirty?: false, conflict: nil)
    |> assign(meta: meta(file))
  end

  # Opens `file` in place of text the user may be looking at, with a new
  # editor so a focused textarea shows it too.
  defp replace(socket, file), do: socket |> load(file) |> update(:revision, &(&1 + 1))

  # "Version 4, changed 5 minutes ago by "Fix the pump"".
  defp meta(%ContextFile{updated_by: by} = file) do
    titles = if by == "owner", do: %{}, else: Threads.titles([by])
    "Version #{file.version}, #{ProjectText.changed(file, titles, DateTime.utc_now())}"
  end

  # The form over `params`, with the context's `%{field => message}` errors.
  defp file_form(params, errors \\ %{}),
    do: to_form(params, as: :file, errors: Enum.map(errors, fn {k, v} -> {k, {v, []}} end))

  # The form's params, with a browser's line breaks in the text made plain.
  defp clean(params),
    do: Map.update(params, "content", "", &String.replace(&1, "\r\n", "\n"))

  defp version(params) do
    case Integer.parse(Map.get(params, "version", "")) do
      {version, ""} -> version
      _other -> nil
    end
  end

  # The text in the editor now.
  defp text_of(form), do: form[:content].value || ""

  # Whether the editor holds something a save would keep: for a new file,
  # any name or text; for a file, text other than what was loaded.
  defp dirty?(nil, params),
    do: Enum.any?(["name", "content"], &(String.trim(params[&1] || "") != ""))

  defp dirty?(%ContextFile{content: content}, params), do: params["content"] != content

  ## Events

  @impl true
  def handle_event("edit", %{"file" => params}, socket) do
    params = clean(params)

    {:noreply,
     assign(socket, form: file_form(params), dirty?: dirty?(socket.assigns.file, params))}
  end

  def handle_event("tab", %{"tab" => tab}, socket) when tab in ["write", "preview"],
    do: {:noreply, assign(socket, tab: tab)}

  def handle_event("save", %{"file" => params}, %{assigns: %{live_action: :new}} = socket) do
    params = clean(params)

    case Projects.create_file(socket.assigns.project.id, params) do
      {:ok, file} -> {:noreply, push_navigate(socket, to: file_path(socket, file))}
      {:error, reason} -> {:noreply, refused(socket, params, reason)}
    end
  end

  def handle_event("save", %{"file" => params}, socket) do
    %{project: project, file: file} = socket.assigns
    params = clean(params)

    case Projects.save_file(project.id, file.name, params["content"], version(params)) do
      {:ok, file} -> {:noreply, socket |> load(file) |> put_flash(:info, "Saved #{file.name}.")}
      {:error, reason} -> {:noreply, refused(socket, params, reason)}
    end
  end

  def handle_event("reload", _params, socket) do
    case Projects.get_file(socket.assigns.project.id, socket.assigns.file.key) do
      %ContextFile{} = file -> {:noreply, replace(socket, file)}
      nil -> {:noreply, assign(socket, conflict: :deleted)}
    end
  end

  def handle_event("keep", _params, socket) do
    case Projects.get_file(socket.assigns.project.id, socket.assigns.file.key) do
      %ContextFile{} = file -> {:noreply, keep_text(socket, file)}
      nil -> {:noreply, assign(socket, conflict: :deleted)}
    end
  end

  def handle_event("delete", _params, socket) do
    %{project: project, file: file} = socket.assigns
    # Deleted now or already gone: either way the file isn't there to show.
    _ = Projects.delete_file(project.id, file.name)

    {:noreply,
     socket
     |> put_flash(:info, "Deleted #{file.name}.")
     |> push_navigate(to: ~p"/projects/#{project.slug}")}
  end

  defp file_path(socket, file),
    do: ~p"/projects/#{socket.assigns.project.slug}/files/#{file.name}"

  # A save that didn't happen: the text stays in the box, with what to do.
  defp refused(socket, params, :stale) do
    socket
    |> assign(form: file_form(params), dirty?: true)
    |> stale()
  end

  defp refused(socket, params, :exists),
    do: refused(socket, params, %{name: "This project already has a file by that name."})

  defp refused(socket, _params, :not_found),
    do: gone(socket, "There's no project called #{socket.assigns.project.slug}.")

  defp refused(socket, params, %{} = errors),
    do: assign(socket, form: file_form(params, errors))

  # The user's text over `file`'s version, so the next save writes over it.
  defp keep_text(socket, file) do
    text = text_of(socket.assigns.form)
    params = %{"content" => text, "version" => Integer.to_string(file.version)}

    socket
    |> assign(file: file, form: file_form(params), conflict: nil, meta: meta(file))
    |> assign(dirty?: text != file.content)
  end

  ## What changed elsewhere

  @impl true
  def handle_info({:project_files_changed, id, key}, %{assigns: assigns} = socket)
      when id == assigns.project.id and is_map(assigns.file) and key == assigns.file.key,
      do: {:noreply, changed_elsewhere(socket)}

  def handle_info({:projects_changed, id}, %{assigns: %{project: %{id: id}}} = socket) do
    case Projects.get(id) do
      %Project{} = project -> {:noreply, assign(socket, project: project)}
      nil -> {:noreply, gone(socket, "There's no project called #{socket.assigns.project.slug}.")}
    end
  end

  def handle_info(:tick, socket) do
    tick()
    {:noreply, assign(socket, meta: meta(socket.assigns.file))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # The open file was written or deleted, here or elsewhere: a clean editor
  # follows it, a dirty one keeps its text and says so.
  defp changed_elsewhere(socket) do
    %{project: project, file: loaded, dirty?: dirty?} = socket.assigns

    case Projects.get_file(project.id, loaded.key) do
      nil ->
        assign(socket, conflict: :deleted)

      %ContextFile{id: id, version: version} when id == loaded.id and version == loaded.version ->
        socket

      %ContextFile{} = file when not dirty? ->
        replace(socket, file)

      %ContextFile{updated_by: by} ->
        assign(socket, conflict: {:changed, by})
    end
  end

  # A save found a newer version than the one it was given: say who wrote
  # it, whatever the editor has loaded.
  defp stale(socket) do
    case Projects.get_file(socket.assigns.project.id, socket.assigns.file.key) do
      %ContextFile{updated_by: by} -> assign(socket, conflict: {:changed, by})
      nil -> assign(socket, conflict: :deleted)
    end
  end

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      shell={@shell}
      socket={@socket}
      active={{:project, @project.slug}}
    >
      <div class="h-full overflow-y-auto">
        <div class="blip-clear-y mx-auto w-full max-w-4xl px-4 py-8 sm:px-6">
          <.header>
            <span id="file-heading" class={@file && "font-mono text-[19px]"}>
              {if @file, do: @file.name, else: "New file"}
            </span>
            <:subtitle>
              <.link
                id="file-project"
                navigate={~p"/projects/#{@project.slug}"}
                class="inline-flex items-center gap-1 transition hover:text-ink"
              >
                <.icon name="hero-arrow-left-micro" class="size-4" /> {@project.name}
              </.link>
            </:subtitle>
            <:actions :if={@file}>
              <.button
                id="file-delete"
                size="sm"
                variant="danger"
                phx-click="delete"
                data-confirm={"Delete #{@file.name}? Threads in #{@project.name} won't see it any more."}
              >
                <.icon name="hero-trash-micro" class="size-4" /> Delete
              </.button>
            </:actions>
          </.header>
          <p :if={@meta} id="file-meta" class="mt-2 text-[12.5px] text-ink-faint">{@meta}</p>

          <.banner
            :if={match?({:changed, _}, @conflict)}
            id="file-changed"
            tone="warn"
            icon="hero-arrow-path"
          >
            {changed_by(@conflict)}
            <:actions>
              <.button id="file-reload" size="sm" phx-click="reload">Load the new version</.button>
              <.button id="file-keep" size="sm" variant="ghost" phx-click="keep">
                Keep my text
              </.button>
            </:actions>
          </.banner>
          <.banner :if={@conflict == :deleted} id="file-deleted" tone="bad" icon="hero-trash">
            This file was deleted while it was open. Save to create it again.
          </.banner>

          <.form
            for={@form}
            id="file-form"
            phx-change="edit"
            phx-submit="save"
            phx-hook=".UnsavedGuard"
            data-dirty={to_string(@dirty?)}
            class="mt-6 space-y-5"
          >
            <.input
              :if={is_nil(@file)}
              field={@form[:name]}
              id="file-name"
              label="Name"
              placeholder="notes.md"
              hint={~s(Letters, digits, ".", "_" and "-". ".md" is added if you leave it off.)}
              autocomplete="off"
              phx-mounted={JS.focus()}
            />
            <.input :if={@file} field={@form[:version]} type="hidden" id="file-version" />

            <div class="overflow-hidden rounded-2xl border border-line bg-surface shadow-xs transition focus-within:border-accent/60 focus-within:shadow-md focus-within:shadow-accent/10">
              <div class="flex items-center justify-between gap-3 border-b border-line bg-sunken/50 px-3 py-2">
                <div
                  role="tablist"
                  class="flex items-center rounded-full border border-line bg-sunken p-0.5"
                >
                  <.tab id="file-tab-write" tab="write" current={@tab}>Write</.tab>
                  <.tab id="file-tab-preview" tab="preview" current={@tab}>Preview</.tab>
                </div>
                <span class="flex items-center gap-1.5 text-[11.5px] text-ink-faint">
                  <.icon name="hero-document-text-micro" class="size-4" /> Markdown
                </span>
              </div>

              <div
                id={"file-editor-#{@revision}"}
                class={["px-4 pt-3 pb-3", @tab == "preview" && "hidden"]}
              >
                <.input
                  field={@form[:content]}
                  id="file-content"
                  type="textarea"
                  rows="20"
                  phx-debounce="400"
                  aria-label="Content"
                  spellcheck="false"
                  placeholder="What should this project's threads know? Markdown works here."
                  class="block min-h-[26rem] w-full resize-y bg-transparent font-mono text-[13px] leading-relaxed text-ink outline-none placeholder:text-ink-faint"
                />
              </div>

              <div
                :if={@tab == "preview"}
                id="file-preview"
                class="markdown-body min-h-[26rem] px-5 py-4 text-ink-soft"
              >
                <%= if String.trim(text_of(@form)) == "" do %>
                  <p class="text-[14px] text-ink-faint">Nothing to preview yet.</p>
                <% else %>
                  {raw(Markdown.to_html(text_of(@form)))}
                <% end %>
              </div>

              <div class="flex items-center justify-between gap-3 border-t border-line px-4 py-3">
                <p class="text-[12.5px] leading-relaxed text-ink-faint">
                  <span
                    :if={@dirty?}
                    id="file-dirty"
                    class="inline-flex items-center gap-1.5 text-ink-soft"
                  >
                    <.dot status={:warn} class="size-1.5" /> Unsaved changes
                  </span>
                  <span :if={!@dirty?}>Every thread in {@project.name} can read and change this file.</span>
                </p>
                <.button
                  type="submit"
                  variant="primary"
                  size="sm"
                  id="file-save"
                  phx-disable-with="Saving..."
                >
                  Save
                </.button>
              </div>
            </div>
          </.form>
        </div>
      </div>
    </Layouts.app>

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
            if (confirm("Leave without saving? Your changes to this file will be lost.")) return
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

  defp changed_by({:changed, "owner"}),
    do: "This file was saved somewhere else while you were editing."

  defp changed_by({:changed, _thread}), do: "A thread changed this file while you were editing."

  attr :id, :string, required: true
  attr :tab, :string, required: true
  attr :current, :string, required: true
  slot :inner_block, required: true

  defp tab(assigns) do
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

  attr :id, :string, required: true
  attr :tone, :string, values: ~w(warn bad), required: true
  attr :icon, :string, required: true
  slot :inner_block, required: true
  slot :actions

  defp banner(assigns) do
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
