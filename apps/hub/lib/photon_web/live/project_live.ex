defmodule PhotonWeb.ProjectLive do
  @moduledoc """
  A project's page, at `/projects/:slug` (section 5.4 of
  `docs/plans/step-2-projects-and-threads.md`): its name, folder and
  purpose (which the user can edit), its threads and its context files.
  The second column is where step 3 adds skills and schedules.

  Both lists are streams (`#project-threads`, `#context-files`). A thread
  row carries whether it is running, so it changes only by re-streaming;
  every change resets the list it touches, since its order may have moved.
  Besides the streams the socket keeps the project, the IDs of its threads
  (to tell which `{:durable_tasks, tasks}` concern it without a query per
  message) and the edit form.

  What it hears, and from where:

    * `{:projects_changed, id}` (through `PhotonWeb.Shell`'s subscription):
      for this project, reload it and its threads (a thread was started or
      sent a message, or the project was edited)
    * `{:durable_tasks, tasks}` (also through the shell): when a task
      belongs to one of its threads, reload the threads, whose running
      state may have changed
    * `{:project_files_changed, id, key}` (`Projects.subscribe_files/1`):
      reload the files, written by the user or a thread

  An unknown slug goes back to `/` with a flash.
  """

  use PhotonWeb, :live_view

  alias Photon.{Markdown, Projects, Threads}
  alias Photon.Projects.Project
  alias PhotonWeb.ProjectText

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Projects.get_by_slug(slug) do
      %Project{} = project ->
        if connected?(socket), do: Projects.subscribe_files(project.id)

        {:ok,
         socket
         |> assign(page_title: project.name, project: project, editing: nil)
         |> stream_configure(:threads, dom_id: &"project-thread-#{&1.thread.id}")
         |> stream_configure(:files, dom_id: &"context-file-#{&1.file.id}")
         |> load_threads()
         |> load_files()}

      nil ->
        {:ok, gone(socket, "There's no project called #{slug}.")}
    end
  end

  defp gone(socket, message), do: socket |> put_flash(:error, message) |> push_navigate(to: ~p"/")

  # The project's threads, most recently active first, each with whether
  # it is running and when it last got a message.
  defp load_threads(socket) do
    threads = Threads.list(socket.assigns.project.id)
    ids = Enum.map(threads, & &1.id)
    running = Threads.running(ids)
    now = DateTime.utc_now()

    rows =
      for thread <- threads do
        %{
          thread: thread,
          running?: MapSet.member?(running, thread.id),
          ago: ProjectText.ago(thread.active_at, now)
        }
      end

    socket
    |> assign(thread_ids: MapSet.new(ids))
    |> stream(:threads, rows, reset: true)
  end

  # The project's files, most recently changed first, each saying who
  # changed it and when.
  defp load_files(socket) do
    files = Projects.list_files(socket.assigns.project.id)

    titles =
      for(%{updated_by: by} <- files, by != "owner", uniq: true, do: by) |> Threads.titles()

    now = DateTime.utc_now()

    rows =
      for file <- files,
          do: %{
            file: file,
            size: ProjectText.size(file.content),
            changed: ProjectText.changed(file, titles, now)
          }

    stream(socket, :files, rows, reset: true)
  end

  ## Editing the name and purpose

  @impl true
  def handle_event("edit", _params, socket) do
    %Project{name: name, purpose: purpose} = socket.assigns.project
    {:noreply, assign(socket, editing: project_form(%{"name" => name, "purpose" => purpose}))}
  end

  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, editing: nil)}

  def handle_event("change", %{"project" => params}, socket),
    do: {:noreply, assign(socket, editing: project_form(params))}

  def handle_event("save", %{"project" => params}, socket) do
    case Projects.update(socket.assigns.project.id, params) do
      {:ok, project} ->
        {:noreply, assign(socket, project: project, page_title: project.name, editing: nil)}

      {:error, :not_found} ->
        {:noreply, gone(socket, "There's no project called #{socket.assigns.project.slug}.")}

      {:error, errors} ->
        {:noreply, assign(socket, editing: project_form(params, errors))}
    end
  end

  # The edit form over `params`, with the context's `%{field => message}` errors.
  defp project_form(params, errors \\ %{}),
    do: to_form(params, as: :project, errors: Enum.map(errors, fn {k, v} -> {k, {v, []}} end))

  ## What changed elsewhere

  @impl true
  def handle_info({:projects_changed, id}, %{assigns: %{project: %{id: id}}} = socket) do
    case Projects.get(id) do
      %Project{} = project ->
        {:noreply, socket |> assign(project: project, page_title: project.name) |> load_threads()}

      nil ->
        {:noreply, gone(socket, "There's no project called #{socket.assigns.project.slug}.")}
    end
  end

  def handle_info({:project_files_changed, id, _key}, %{assigns: %{project: %{id: id}}} = socket),
    do: {:noreply, load_files(socket)}

  def handle_info({:durable_tasks, tasks}, socket) do
    if Enum.any?(tasks, &MapSet.member?(socket.assigns.thread_ids, &1.conversation_id)),
      do: {:noreply, load_threads(socket)},
      else: {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

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
        <div class="blip-clear-y mx-auto w-full max-w-5xl px-4 py-8 sm:px-6">
          <.header>
            <span id="project-name">{@project.name}</span>
            <:subtitle>
              <span id="project-folder" class="inline-flex items-center gap-1.5">
                <.icon name="hero-folder-micro" class="size-4 text-ink-faint" /> Folder
                <code class="rounded bg-sunken px-1.5 py-px font-mono text-[12.5px] text-ink">
                  {@project.slug}
                </code>
                in each machine's workspace
              </span>
            </:subtitle>
          </.header>

          <section class="mt-6 rounded-2xl border border-line bg-surface p-5 shadow-xs">
            <div class="flex items-center justify-between gap-3">
              <h2 class="text-[13px] font-semibold text-ink">Purpose</h2>
              <.button
                :if={is_nil(@editing)}
                id="edit-project"
                size="sm"
                variant="ghost"
                phx-click="edit"
              >
                <.icon name="hero-pencil-square-micro" class="size-4" /> Edit
              </.button>
            </div>
            <div
              :if={is_nil(@editing)}
              id="project-purpose"
              class="markdown-body mt-2 text-[14.5px] text-ink-soft"
            >
              {raw(Markdown.to_html(@project.purpose))}
            </div>
            <.form
              :if={@editing}
              for={@editing}
              id="project-edit-form"
              phx-change="change"
              phx-submit="save"
              class="mt-3 space-y-4"
            >
              <.input field={@editing[:name]} id="project-edit-name" label="Name" autocomplete="off" />
              <.input
                field={@editing[:purpose]}
                id="project-edit-purpose"
                type="textarea"
                rows="6"
                label="Purpose"
                hint="Renaming keeps the project's folder."
              />
              <div class="flex justify-end gap-2">
                <.button
                  type="button"
                  size="sm"
                  variant="ghost"
                  phx-click="cancel_edit"
                  id="project-cancel"
                >
                  Cancel
                </.button>
                <.button type="submit" size="sm" variant="primary" id="project-save">Save</.button>
              </div>
            </.form>
          </section>

          <div class="mt-9 grid gap-9 lg:grid-cols-[minmax(0,3fr)_minmax(0,2fr)] lg:gap-8">
            <section>
              <.section_head title="Threads">
                <.button
                  navigate={~p"/projects/#{@project.slug}/threads/new"}
                  id="project-new-thread"
                  size="sm"
                >
                  <.icon name="hero-plus-micro" class="size-4" /> New thread
                </.button>
              </.section_head>
              <div id="project-threads" phx-update="stream" class="mt-3 space-y-2">
                <p
                  id="no-threads"
                  class="hidden rounded-2xl border border-dashed border-line-strong px-5 py-6 text-[14px] leading-relaxed text-ink-soft only:block"
                >
                  No threads yet. Start one to put an agent to work on this project.
                </p>
                <.link
                  :for={{dom_id, row} <- @streams.threads}
                  id={dom_id}
                  navigate={~p"/projects/#{@project.slug}/threads/#{row.thread.id}"}
                  data-running={row.running? && "true"}
                  class="group flex items-center gap-3 rounded-xl border border-line bg-surface px-4 py-3 shadow-xs transition hover:border-line-strong hover:bg-sunken/40"
                >
                  <.icon
                    name="hero-chat-bubble-left-right"
                    class="size-4 shrink-0 text-ink-faint transition group-hover:text-ink-soft"
                  />
                  <span class="min-w-0 flex-1 truncate text-[14px] text-ink">{row.thread.title}</span>
                  <span
                    :if={row.running?}
                    class="flex shrink-0 items-center gap-1.5 text-[12px] text-accent-strong"
                  >
                    <.dot status={:busy} class="size-1.5" /> running
                  </span>
                  <span :if={!row.running?} class="shrink-0 text-[12px] text-ink-faint">
                    {row.ago}
                  </span>
                </.link>
              </div>
            </section>

            <section>
              <.section_head title="Context files">
                <.button navigate={~p"/projects/#{@project.slug}/files/new"} id="new-file" size="sm">
                  <.icon name="hero-plus-micro" class="size-4" /> New file
                </.button>
              </.section_head>
              <div id="context-files" phx-update="stream" class="mt-3 space-y-2">
                <p
                  id="no-files"
                  class="hidden rounded-2xl border border-dashed border-line-strong px-5 py-6 text-[14px] leading-relaxed text-ink-soft only:block"
                >
                  No context files yet. Threads write notes here as they work, and so can you.
                </p>
                <.link
                  :for={{dom_id, row} <- @streams.files}
                  id={dom_id}
                  navigate={~p"/projects/#{@project.slug}/files/#{row.file.name}"}
                  class="group flex items-start gap-3 rounded-xl border border-line bg-surface px-4 py-3 shadow-xs transition hover:border-line-strong hover:bg-sunken/40"
                >
                  <.icon
                    name="hero-document-text"
                    class="mt-0.5 size-4 shrink-0 text-ink-faint transition group-hover:text-ink-soft"
                  />
                  <div class="min-w-0 flex-1">
                    <div class="flex items-baseline gap-2">
                      <span class="truncate font-mono text-[13px] text-ink">{row.file.name}</span>
                      <span class="ml-auto shrink-0 text-[11.5px] tabular-nums text-ink-faint">
                        {row.size}
                      </span>
                    </div>
                    <p class="mt-0.5 truncate text-[12px] text-ink-faint">{row.changed}</p>
                  </div>
                </.link>
              </div>
            </section>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp section_head(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-3">
      <h2 class="text-[11px] font-semibold tracking-wider text-ink-faint uppercase">{@title}</h2>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
