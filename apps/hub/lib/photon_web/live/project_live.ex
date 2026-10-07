defmodule PhotonWeb.ProjectLive do
  @moduledoc """
  A project's page, at `/projects/:slug` (section 5.4 of
  `docs/plans/step-2-projects-and-threads.md`, and section 6.6 of
  `docs/plans/step-3-skills-and-schedules.md`): its name, folder and
  purpose (which the user can edit), its threads, and in the second
  column its context files, the skills turned on for it (threads also get
  the skills turned on for each machine), and its schedules.

  The lists are streams (`#project-threads`, `#context-files`,
  `#project-skills`, `#project-schedules`). The threads are the project's
  board (`Photon.Threads.board/1`, section 10.5 of
  `docs/plans/step-4-blip-as-coordinator.md`): each row shows its state
  (`#project-thread-<id>-state`) with the mark and words the sidebar and
  Home use (`PhotonWeb.CoreComponents.state_mark/1`,
  `PhotonWeb.ThreadText.state/1`), and how long ago it was active when
  nothing is going on in it. A row changes only by re-streaming; every
  change resets the list it touches, since its order may have moved. Besides the streams
  the socket keeps the project, the IDs of its threads (to tell which
  `{:durable_tasks, tasks}` concern it without a query per message), the
  edit form, and for the schedules the title of the thread each one wakes
  (by schedule ID, which is also how a button's ID from the browser is
  checked to be one of this project's), how many there are and whether
  scheduled work is allowed (`Photon.Schedules.consent?/0`).

  Skills: the ones on here are a stream, each with `Turn off`; `Turn on
  skills` opens a picker, a stream of the skills not on here, read only
  while it is open. Clicking one turns it on (`Photon.Skills.enable/2`);
  a refused enable (30 on already) shows in the picker.

  Schedules: each row says when it runs next or that it stopped
  (`PhotonWeb.ScheduleComponents`), where it goes, and what its last run
  did, with Run now (`Photon.Schedules.run_now/1`, whose outcome is a
  flash), Edit and Delete. While scheduled work is off, a banner says the
  schedules skip and links to Settings.

  What it hears, and from where:

    * `{:projects_changed, id}` (through `PhotonWeb.Shell`'s subscription):
      for this project, reload it, its threads and its schedules (a thread
      was started or sent a message, or the project was edited; the
      schedule rows name threads, whose titles change when the model or
      the owner renames them)
    * `{:durable_tasks, tasks}` (also through the shell): when a task
      belongs to one of its threads, reload the threads, whose running
      state may have changed
    * `{:questions_changed, thread_id}` (also through the shell): when it
      is one of its threads, reload the threads, since an `ask_blip`
      question moves a thread between asking Blip and waiting on you
    * `{:settings_changed, _}` (also through the shell): whether scheduled
      work is allowed, for the banner
    * `{:project_files_changed, id, key}` (`Projects.subscribe_files/1`):
      reload the files, written by the user or a thread
    * `{:skills_changed, _}` (`Skills.subscribe/0`): reload the skills on
      here, and the picker when it is open
    * `{:schedules_changed, id}` (`Schedules.subscribe/0`): for this
      project, reload the schedules (one was changed, fired or stopped)
    * `:tick`, its own timer, once a minute: reload the threads and files,
      so "just now" turns into "5 minutes ago" on a page left open. The
      schedules' times are absolute and the browser formats them, so the
      tick leaves them alone

  An unknown slug goes back to `/` with a flash.
  """

  use PhotonWeb, :live_view

  import PhotonWeb.ScheduleComponents

  alias Photon.{Markdown, Projects, Schedules, Skills, Threads}
  alias Photon.Projects.Project
  alias PhotonWeb.{ProjectText, ScheduleText, ThreadText}

  @tick_ms :timer.minutes(1)

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Projects.get_by_slug(slug) do
      %Project{} = project ->
        if connected?(socket), do: subscribe(project)

        {:ok,
         socket
         |> assign(page_title: project.name, project: project, editing: nil)
         |> assign(picking: false, skill_error: nil, skill_count: 0)
         |> stream_configure(:threads, dom_id: &"project-thread-#{&1.thread.id}")
         |> stream_configure(:files, dom_id: &"context-file-#{&1.file.id}")
         |> stream_configure(:skills, dom_id: &"project-skill-#{&1.id}")
         |> stream_configure(:skill_options, dom_id: &"project-skill-option-#{&1.id}")
         |> stream_configure(:schedules, dom_id: &"schedule-#{&1.id}")
         |> stream(:skill_options, [])
         |> load_threads()
         |> load_files()
         |> load_skills()
         |> load_schedules()}

      nil ->
        {:ok, gone(socket, "There's no project called #{slug}.")}
    end
  end

  defp subscribe(project) do
    :ok = Projects.subscribe_files(project.id)
    :ok = Skills.subscribe()
    :ok = Schedules.subscribe()
    tick()
  end

  defp gone(socket, message), do: socket |> put_flash(:error, message) |> push_navigate(to: ~p"/")

  # The rows say how long ago things happened, so they are redrawn once a minute.
  defp tick do
    # Never cancelled: it fires once and the next is set then; it dies with the page.
    _timer = Process.send_after(self(), :tick, @tick_ms)
    :ok
  end

  # The project's threads, most recently active first, each with its
  # state and when it last got a message.
  defp load_threads(socket) do
    board = Threads.board({:project, socket.assigns.project.id})
    now = DateTime.utc_now()

    rows =
      for entry <- board, do: Map.put(entry, :ago, ProjectText.ago(entry.thread.active_at, now))

    socket
    |> assign(thread_ids: MapSet.new(board, & &1.id))
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

  defp scope(socket), do: {:project, socket.assigns.project.id}

  # The skills on here, by name, and the picker's when it is open.
  defp load_skills(socket) do
    socket
    |> stream(:skills, Skills.enabled(scope(socket)), reset: true)
    |> load_picker()
  end

  # The skills not on here, by name, and how many skills there are at all
  # (none: the picker points to the Skills page).
  defp load_picker(%{assigns: %{picking: false}} = socket), do: socket

  defp load_picker(socket) do
    scope = scope(socket)
    listed = Skills.list()
    off = for %{skill: skill, scopes: scopes} <- listed, scope not in scopes, do: skill

    socket
    |> assign(skill_count: length(listed))
    |> stream(:skill_options, off, reset: true)
  end

  # The project's schedules, each with the titles of the threads its row
  # names: the one it wakes and the one its last run started.
  defp load_schedules(socket) do
    listed = Schedules.list(scope(socket))
    titles = thread_titles(listed)

    rows = for item <- listed, do: Map.put(item, :titles, titles)
    targets = Map.new(listed, &{&1.id, title(titles, &1.schedule.conversation_id)})

    socket
    |> assign(targets: targets, consent?: Schedules.consent?())
    |> stream(:schedules, rows, reset: true)
  end

  defp thread_titles(listed) do
    listed
    |> Enum.flat_map(&[&1.schedule.conversation_id, &1.schedule.last_thread_id])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Threads.titles()
  end

  defp title(_titles, nil), do: nil
  defp title(titles, id), do: Map.get(titles, id)

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

  ## Skills

  def handle_event("toggle_picker", _params, socket) do
    {:noreply,
     socket |> assign(picking: !socket.assigns.picking, skill_error: nil) |> load_picker()}
  end

  def handle_event("enable_skill", %{"id" => id}, socket) do
    case Skills.enable(id, scope(socket)) do
      :ok ->
        {:noreply, socket |> assign(skill_error: nil) |> load_skills()}

      {:error, :not_found} ->
        {:noreply, socket |> assign(skill_error: "That skill was deleted.") |> load_skills()}

      {:error, message} ->
        {:noreply, assign(socket, skill_error: message)}
    end
  end

  def handle_event("disable_skill", %{"id" => id}, socket) do
    :ok = Skills.disable(id, scope(socket))
    {:noreply, load_skills(socket)}
  end

  ## Schedules

  # Only this project's schedules: the ID comes from the browser.
  def handle_event("run_schedule", %{"id" => id}, socket) do
    with {:ok, title} <- Map.fetch(socket.assigns.targets, id),
         {:ok, outcome} <- Schedules.run_now(id) do
      {:noreply, socket |> put_flash(:info, ScheduleText.ran(outcome, title)) |> load_schedules()}
    else
      _gone ->
        {:noreply, socket |> put_flash(:error, "That schedule was deleted.") |> load_schedules()}
    end
  end

  def handle_event("delete_schedule", %{"id" => id}, socket) do
    socket =
      with true <- Map.has_key?(socket.assigns.targets, id),
           :ok <- Schedules.delete(id) do
        put_flash(socket, :info, "Schedule deleted.")
      else
        # Not this project's, or deleted elsewhere first: the list is read again.
        _gone -> socket
      end

    {:noreply, load_schedules(socket)}
  end

  # The edit form over `params`, with the context's `%{field => message}` errors.
  defp project_form(params, errors \\ %{}),
    do: to_form(params, as: :project, errors: Enum.map(errors, fn {k, v} -> {k, {v, []}} end))

  ## What changed elsewhere

  @impl true
  def handle_info({:projects_changed, id}, %{assigns: %{project: %{id: id}}} = socket) do
    case Projects.get(id) do
      %Project{} = project ->
        {:noreply,
         socket
         |> assign(project: project, page_title: project.name)
         |> load_threads()
         |> load_schedules()}

      nil ->
        {:noreply, gone(socket, "There's no project called #{socket.assigns.project.slug}.")}
    end
  end

  def handle_info({:project_files_changed, id, _key}, %{assigns: %{project: %{id: id}}} = socket),
    do: {:noreply, load_files(socket)}

  def handle_info({:schedules_changed, id}, %{assigns: %{project: %{id: id}}} = socket),
    do: {:noreply, load_schedules(socket)}

  def handle_info({:skills_changed, _id}, socket), do: {:noreply, load_skills(socket)}

  def handle_info({:settings_changed, _settings}, socket),
    do: {:noreply, assign(socket, consent?: Schedules.consent?())}

  def handle_info(:tick, socket) do
    tick()
    {:noreply, socket |> load_threads() |> load_files()}
  end

  def handle_info({:questions_changed, thread_id}, socket) do
    if MapSet.member?(socket.assigns.thread_ids, thread_id),
      do: {:noreply, load_threads(socket)},
      else: {:noreply, socket}
  end

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
                  class={[
                    "group flex items-center gap-3 rounded-xl border bg-surface px-4 py-3 shadow-xs transition hover:bg-sunken/40",
                    if(row.state == :waiting,
                      do: "border-warn/35 hover:border-warn/60",
                      else: "border-line hover:border-line-strong"
                    )
                  ]}
                >
                  <.icon
                    name="hero-chat-bubble-left-right"
                    class="size-4 shrink-0 text-ink-faint transition group-hover:text-ink-soft"
                  />
                  <span class="min-w-0 flex-1 truncate text-[14px] text-ink">{row.thread.title}</span>
                  <.thread_state id={"#{dom_id}-state"} row={row} />
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

              <.skills_section
                skills={@streams.skills}
                options={@streams.skill_options}
                picking={@picking}
                skill_error={@skill_error}
                skill_count={@skill_count}
              />
              <.schedules_section
                schedules={@streams.schedules}
                project={@project}
                consent?={@consent?}
                any?={map_size(@targets) > 0}
              />
            </section>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :row, :map, required: true, doc: "a board entry, with `ago`"

  # A thread row's state: the mark and words while something is going on
  # in it (running, asking Blip, waiting on the owner, failed, finished
  # unread), with how long ago it was active once it isn't running, and
  # only that when it's quiet or idle.
  defp thread_state(assigns) do
    assigns = assign(assigns, state: assigns.row.state, words: ThreadText.state(assigns.row))

    ~H"""
    <span
      id={@id}
      data-state={@state}
      title={@words}
      class="flex shrink-0 items-center gap-1.5 text-[12px] text-ink-faint"
    >
      <%= if @state in [:quiet, :idle] do %>
        <.icon :if={@state == :quiet} name="hero-pause-circle-micro" class="size-3.5" />
        {@row.ago}
      <% else %>
        <.state_mark state={@state} class="size-3.5" />
        <span class={[
          "font-medium",
          @state in [:running, :asking] && "text-accent-strong",
          @state == :waiting && "text-ink",
          @state == :failed && "text-bad",
          @state == :unread && "text-ink-soft"
        ]}>
          {@words}
        </span>
        <span :if={@state not in [:running, :asking]} class="hidden sm:inline">
          · {@row.ago}
        </span>
      <% end %>
    </span>
    """
  end

  attr :skills, :any, required: true, doc: "the stream of skills on here"
  attr :options, :any, required: true, doc: "the picker's stream of skills not on here"
  attr :picking, :boolean, required: true
  attr :skill_error, :string, default: nil
  attr :skill_count, :integer, required: true

  # The skills this project's threads may load, and the picker that turns
  # more on.
  defp skills_section(assigns) do
    ~H"""
    <div class="mt-9">
      <.section_head title="Skills">
        <.button
          id="project-add-skill"
          size="sm"
          phx-click="toggle_picker"
          aria-expanded={to_string(@picking)}
          aria-controls="project-skill-picker"
        >
          <.icon name={if(@picking, do: "hero-x-mark-micro", else: "hero-plus-micro")} class="size-4" />
          {if(@picking, do: "Done", else: "Turn on skills")}
        </.button>
      </.section_head>

      <div
        :if={@picking}
        id="project-skill-picker"
        class="animate-rise mt-3 rounded-xl border border-line bg-sunken/60 p-1.5"
      >
        <p class="px-2.5 pt-1.5 pb-2 text-[12px] text-ink-faint">
          Turn a skill on for this project's threads.
        </p>
        <p
          :if={@skill_error}
          id="project-skill-error"
          role="alert"
          class="mx-2.5 mb-2 flex items-start gap-1.5 text-[12.5px] leading-snug text-bad"
        >
          <.icon name="hero-exclamation-circle-micro" class="mt-px size-4 shrink-0" />
          {@skill_error}
        </p>
        <div
          :if={@skill_count > 0}
          id="project-skill-options"
          phx-update="stream"
          class="max-h-80 space-y-0.5 overflow-y-auto"
        >
          <p
            id="no-skill-options"
            class="hidden px-2.5 pb-2 text-[13px] text-ink-soft only:block"
          >
            Every skill is on here already.
          </p>
          <button
            :for={{dom_id, skill} <- @options}
            id={dom_id}
            type="button"
            phx-click="enable_skill"
            phx-value-id={skill.id}
            class="group flex w-full items-start gap-2.5 rounded-lg px-2.5 py-2 text-left transition hover:bg-surface hover:shadow-xs phx-click-loading:opacity-60"
          >
            <.icon
              name="hero-plus-circle-micro"
              class="mt-px size-4 shrink-0 text-ink-faint transition group-hover:text-accent-strong"
            />
            <span class="min-w-0 flex-1">
              <span class="block truncate font-mono text-[13px] text-ink">{skill.name}</span>
              <span class="block truncate text-[12px] text-ink-faint" title={skill.description}>
                {skill.description}
              </span>
            </span>
          </button>
        </div>
        <p
          :if={@skill_count == 0}
          id="project-skill-none"
          class="px-2.5 pb-2 text-[13px] text-ink-soft"
        >
          No skills yet.
          <.link
            id="project-skills-page"
            navigate={~p"/skills"}
            class="font-medium text-accent-strong underline underline-offset-2"
          >
            Write or install one
          </.link>
          on the Skills page.
        </p>
      </div>

      <div id="project-skills" phx-update="stream" class="mt-3 space-y-2">
        <p
          id="no-project-skills"
          class="hidden rounded-2xl border border-dashed border-line-strong px-5 py-6 text-[14px] leading-relaxed text-ink-soft only:block"
        >
          No skills turned on. Skills are instructions this project's threads load when a task calls for them. Skills turned on for a machine reach them too.
        </p>
        <div
          :for={{dom_id, skill} <- @skills}
          id={dom_id}
          class="group flex items-start gap-3 rounded-xl border border-line bg-surface px-4 py-3 shadow-xs transition hover:border-line-strong"
        >
          <.icon
            name="hero-book-open"
            class="mt-0.5 size-4 shrink-0 text-ink-faint transition group-hover:text-ink-soft"
          />
          <div class="min-w-0 flex-1">
            <.link
              id={"#{dom_id}-link"}
              navigate={~p"/skills/#{skill.name}"}
              class="block truncate font-mono text-[13px] text-ink transition hover:text-accent-strong"
            >
              {skill.name}
            </.link>
            <p class="mt-0.5 truncate text-[12px] text-ink-faint" title={skill.description}>
              {skill.description}
            </p>
          </div>
          <.button
            id={"#{dom_id}-off"}
            size="sm"
            variant="ghost"
            phx-click="disable_skill"
            phx-value-id={skill.id}
            class="-my-1 -mr-2 shrink-0"
          >
            Turn off
          </.button>
        </div>
      </div>
    </div>
    """
  end

  attr :schedules, :any, required: true, doc: "the stream of the project's schedules"
  attr :project, Project, required: true
  attr :consent?, :boolean, required: true
  attr :any?, :boolean, required: true, doc: "whether the project has schedules"

  # The project's schedules, each with when it runs, where it goes and what
  # its last run did.
  defp schedules_section(assigns) do
    ~H"""
    <div class="mt-9">
      <.section_head title="Schedules">
        <.button
          id="new-schedule"
          size="sm"
          navigate={~p"/projects/#{@project.slug}/schedules/new"}
        >
          <.icon name="hero-plus-micro" class="size-4" /> New schedule
        </.button>
      </.section_head>

      <div
        :if={@any? and not @consent?}
        id="schedules-consent"
        role="status"
        class="mt-3 flex items-start gap-2.5 rounded-xl border border-warn/30 bg-warn-soft px-3.5 py-3 text-[13px] leading-relaxed text-ink"
      >
        <.icon name="hero-pause-circle" class="mt-0.5 size-4 shrink-0 text-warn" />
        <p>
          Scheduled work is off, so these skip their runs.
          <.link
            id="schedules-consent-settings"
            navigate={~p"/settings"}
            class="font-medium text-accent-strong underline underline-offset-2"
          >
            Turn it on in Settings
          </.link>
          to let schedules use your ChatGPT plan while you're away.
        </p>
      </div>

      <div id="project-schedules" phx-update="stream" class="mt-3 space-y-2">
        <p
          id="no-schedules"
          class="hidden rounded-2xl border border-dashed border-line-strong px-5 py-6 text-[14px] leading-relaxed text-ink-soft only:block"
        >
          No schedules. A schedule starts a thread, or wakes one, at set times.
        </p>
        <article
          :for={{dom_id, item} <- @schedules}
          id={dom_id}
          class="group rounded-xl border border-line bg-surface px-4 pt-3 pb-2 shadow-xs transition hover:border-line-strong"
        >
          <div class="flex items-start gap-3">
            <.icon
              name="hero-clock"
              class="mt-0.5 size-4 shrink-0 text-ink-faint transition group-hover:text-ink-soft"
            />
            <div class="min-w-0 flex-1">
              <%!-- On one line: whitespace-pre-line would show the break before it. --%>
              <p
                id={"#{dom_id}-prompt"}
                class="line-clamp-2 text-[14px] leading-snug whitespace-pre-line text-ink"
                title={item.schedule.prompt}
                phx-no-format
              >{item.schedule.prompt}</p>
              <.schedule_when id={dom_id} item={item} />
              <.schedule_target id={dom_id} item={item} project={@project} />
              <.last_run
                id={dom_id}
                schedule={item.schedule}
                thread_title={item.titles[item.schedule.last_thread_id]}
                thread_path={
                  item.schedule.last_thread_id &&
                    ~p"/projects/#{@project.slug}/threads/#{item.schedule.last_thread_id}"
                }
                class="mt-0.5"
              />
              <div class="-ml-2.5 mt-1.5 flex items-center gap-0.5">
                <.button
                  id={"#{dom_id}-run"}
                  size="sm"
                  variant="ghost"
                  phx-click="run_schedule"
                  phx-value-id={item.id}
                  class="phx-click-loading:opacity-60"
                >
                  <.icon name="hero-play-micro" class="size-4" /> Run now
                </.button>
                <.button
                  id={"#{dom_id}-edit"}
                  size="sm"
                  variant="ghost"
                  navigate={~p"/projects/#{@project.slug}/schedules/#{item.id}"}
                >
                  <.icon name="hero-pencil-square-micro" class="size-4" /> Edit
                </.button>
                <.button
                  id={"#{dom_id}-delete"}
                  size="sm"
                  variant="ghost"
                  phx-click="delete_schedule"
                  phx-value-id={item.id}
                  data-confirm="Delete this schedule? Threads it started stay."
                  class="ml-auto hover:bg-bad-soft hover:text-bad"
                >
                  <.icon name="hero-trash-micro" class="size-4" /> Delete
                </.button>
              </div>
            </div>
          </div>
        </article>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :item, :map, required: true
  attr :project, Project, required: true

  # Where the schedule's firings go: a new thread each time, or the thread
  # it wakes, linked.
  defp schedule_target(%{item: %{schedule: schedule, titles: titles}} = assigns) do
    {words, linked} = ScheduleText.target(schedule, title(titles, schedule.conversation_id))
    assigns = assign(assigns, words: words, linked: linked)

    ~H"""
    <p
      id={"#{@id}-target"}
      class="mt-0.5 flex min-w-0 items-center gap-1 text-[12px] text-ink-faint"
    >
      <.icon
        name={if(@linked, do: "hero-chat-bubble-left-right-micro", else: "hero-plus-micro")}
        class="size-3.5 shrink-0"
      />
      <span class="shrink-0">{@words}</span>
      <.link
        :if={@linked}
        id={"#{@id}-thread"}
        navigate={~p"/projects/#{@project.slug}/threads/#{@item.schedule.conversation_id}"}
        class="min-w-0 truncate text-ink-soft underline decoration-line-strong underline-offset-2 transition hover:text-ink hover:decoration-ink-faint"
      >
        {@linked}
      </.link>
    </p>
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
