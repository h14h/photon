defmodule PhotonWeb.SkillLive do
  @moduledoc """
  One skill (section 6.4 of `docs/plans/step-3-skills-and-schedules.md`):
  `:new` at `/skills/new` writes one, `:edit` at `/skills/:name` shows,
  edits and turns one on.

  The editor is a form over a plain map (`name`, `description`,
  `instructions` and, when editing, the hidden `version` it loaded), with
  `Write` and `Preview` tabs for the instructions. Saving hands it to
  `Photon.Skills`, which checks it and the version; its errors show under
  their fields. A save that renames the skill patches the URL to the new
  name. The form asks before the owner leaves it with unsaved text
  (`PhotonWeb.EditorComponents.guarded_form/1`, shared with the context
  file editor).

  "Turned on for" has a switch for Blip and one per project (a stream),
  each calling `Skills.enable/2` or `disable/2` with the state it should
  end in; a refused enable is a flash.

  The page follows `Skills.subscribe/0`. A toggle and a save announce the
  same `{:skills_changed, id}`, so for the open skill the handler does two
  separate things:

    * it always re-reads where the skill is on, so a toggle made on
      `/skills` or a project page shows here
    * only when the stored version differs from the one the form loaded
      does a clean form load it (following a rename to its URL), or a
      dirty one keep the owner's text and show `#skill-stale`, with `Load
      the saved version` and `Keep my text` (takes the stored version's
      number, so the next save writes over it). A toggle made here while
      the owner types leaves the form alone.

  A save with an old version (`:stale`) shows the same banner and keeps
  the text. When the text is replaced from the server, the fields get new
  DOM IDs (`@revision`), because LiveView leaves a focused field's value
  alone. A deleted skill sends the page to `/skills`.

  `{:projects_changed, _}` (through `PhotonWeb.Shell`) re-reads the
  projects, so a new or renamed project shows among the switches.
  Everything else the shell passes on is ignored. An unknown skill goes
  back to `/skills` with a flash.
  """

  use PhotonWeb, :live_view

  import PhotonWeb.EditorComponents

  alias Photon.{Markdown, Projects, Skills}
  alias Photon.Skills.Skill
  alias PhotonWeb.SkillText

  @fields ["name", "description", "instructions"]

  @impl true
  def mount(params, _session, socket) do
    case skill(params, socket.assigns.live_action) do
      {:ok, skill} ->
        if skill && connected?(socket), do: :ok = Skills.subscribe()

        {:ok,
         socket
         |> assign(tab: "write", revision: 0, leaving?: false)
         |> stream_configure(:projects, dom_id: &"skill-scope-row-#{&1.id}")
         |> open(skill)}

      {:error, message} ->
        {:ok, gone(socket, message)}
    end
  end

  defp skill(_params, :new), do: {:ok, nil}

  defp skill(%{"name" => name}, :edit) do
    case Skills.get_by_name(name) do
      %Skill{} = skill -> {:ok, skill}
      nil -> {:error, "There's no skill called #{name}."}
    end
  end

  defp gone(socket, message),
    do: socket |> put_flash(:error, message) |> push_navigate(to: ~p"/skills")

  # A rename patches the URL to the new name, which is already open. Any
  # other name (the browser's back button after a rename) opens that skill.
  @impl true
  def handle_params(%{"name" => name}, _uri, %{assigns: %{skill: %Skill{name: name}}} = socket),
    do: {:noreply, socket}

  def handle_params(%{"name" => _name} = params, _uri, %{assigns: %{skill: %Skill{}}} = socket) do
    case skill(params, :edit) do
      {:ok, skill} -> {:noreply, socket |> open(skill) |> update(:revision, &(&1 + 1))}
      {:error, message} -> {:noreply, gone(socket, message)}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  ## The editor's state

  # Opens `skill` (nil for a new one) in a clean editor, with where it is on.
  defp open(socket, skill) do
    socket
    |> assign(page_title: title(skill))
    |> load(skill)
    |> load_scopes()
  end

  defp title(nil), do: "Write a skill"
  defp title(%Skill{name: name}), do: name

  defp load(socket, nil) do
    form = skill_form(%{"name" => "", "description" => "", "instructions" => ""})
    assign(socket, skill: nil, form: form, dirty?: false, stale?: false)
  end

  defp load(socket, %Skill{} = skill) do
    params = %{
      "name" => skill.name,
      "description" => skill.description,
      "instructions" => skill.instructions,
      "version" => Integer.to_string(skill.version)
    }

    assign(socket, skill: skill, form: skill_form(params), dirty?: false, stale?: false)
  end

  # Opens `skill` in place of text the owner may be looking at, with new
  # fields so a focused one shows it too, and its name in the URL.
  defp replace(socket, %Skill{} = skill) do
    renamed? = skill.name != socket.assigns.skill.name
    socket = socket |> open(skill) |> update(:revision, &(&1 + 1))
    if renamed?, do: push_patch(socket, to: ~p"/skills/#{skill.name}"), else: socket
  end

  # Where the open skill is on: Blip's switch, and one per project by name.
  defp load_scopes(%{assigns: %{skill: nil}} = socket),
    do: socket |> assign(blip?: false) |> stream(:projects, [], reset: true)

  defp load_scopes(%{assigns: %{skill: skill}} = socket) do
    scopes = Skills.scopes(skill.id)

    rows =
      for p <- Projects.list(), do: %{id: p.id, name: p.name, on?: {:project, p.id} in scopes}

    socket
    |> assign(blip?: :blip in scopes)
    |> stream(:projects, rows, reset: true)
  end

  # The form over `params`, with the context's `%{field => message}` errors.
  defp skill_form(params, errors \\ %{}),
    do: to_form(params, as: :skill, errors: Enum.map(errors, fn {k, v} -> {k, {v, []}} end))

  # The form's params, with a browser's line breaks made plain.
  defp clean(params) do
    Map.new(params, fn
      {key, value} when is_binary(value) -> {key, String.replace(value, "\r\n", "\n")}
      pair -> pair
    end)
  end

  defp version(params) do
    case Integer.parse(Map.get(params, "version", "")) do
      {version, ""} when version > 0 -> version
      _other -> 0
    end
  end

  # The instructions in the editor now.
  defp instructions(form), do: form[:instructions].value || ""

  # Whether the editor holds something a save would keep: for a new skill,
  # anything typed; for a skill, a field other than what was loaded.
  defp dirty?(nil, params), do: Enum.any?(@fields, &(String.trim(params[&1] || "") != ""))

  defp dirty?(%Skill{} = skill, params) do
    stored = %{
      "name" => skill.name,
      "description" => skill.description,
      "instructions" => skill.instructions
    }

    Enum.any?(@fields, &((params[&1] || "") != stored[&1]))
  end

  ## Events

  @impl true
  def handle_event("edit", %{"skill" => params}, socket) do
    params = clean(params)

    {:noreply,
     assign(socket, form: skill_form(params), dirty?: dirty?(socket.assigns.skill, params))}
  end

  def handle_event("tab", %{"tab" => tab}, socket) when tab in ["write", "preview"],
    do: {:noreply, assign(socket, tab: tab)}

  def handle_event("save", %{"skill" => params}, %{assigns: %{live_action: :new}} = socket) do
    params = clean(params)

    case Skills.create(params) do
      {:ok, skill} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved #{skill.name}. It's off everywhere; turn it on below.")
         |> push_navigate(to: ~p"/skills/#{skill.name}")}

      {:error, errors} ->
        {:noreply, assign(socket, form: skill_form(params, errors), dirty?: dirty?(nil, params))}
    end
  end

  def handle_event("save", %{"skill" => params}, socket) do
    params = clean(params)

    case Skills.update(socket.assigns.skill.id, params, version(params)) do
      {:ok, skill} ->
        {:noreply, socket |> saved(skill) |> put_flash(:info, "Saved #{skill.name}.")}

      {:error, :stale} ->
        {:noreply, refused_stale(socket, params)}

      {:error, :not_found} ->
        {:noreply, deleted(socket)}

      {:error, errors} ->
        {:noreply, assign(socket, form: skill_form(params, errors))}
    end
  end

  def handle_event("reload", _params, socket) do
    case Skills.get(socket.assigns.skill.id) do
      %Skill{} = skill -> {:noreply, replace(socket, skill)}
      nil -> {:noreply, deleted(socket)}
    end
  end

  def handle_event("keep", _params, socket) do
    case Skills.get(socket.assigns.skill.id) do
      %Skill{} = skill -> {:noreply, keep_text(socket, skill)}
      nil -> {:noreply, deleted(socket)}
    end
  end

  def handle_event("scope", %{"scope" => scope, "on" => on}, socket) do
    %Skill{id: id} = socket.assigns.skill
    scope = if scope == "blip", do: :blip, else: {:project, scope}

    case if(on == "true", do: Skills.enable(id, scope), else: Skills.disable(id, scope)) do
      :ok -> {:noreply, load_scopes(socket)}
      {:error, :not_found} -> {:noreply, deleted(socket)}
      {:error, message} -> {:noreply, socket |> put_flash(:error, message) |> load_scopes()}
    end
  end

  def handle_event("delete", _params, socket) do
    %Skill{id: id, name: name} = socket.assigns.skill
    # Deleted now or already gone: either way the skill isn't there to show.
    _ = Skills.delete(id)

    {:noreply,
     socket
     |> assign(leaving?: true)
     |> put_flash(:info, "Deleted #{name}.")
     |> push_navigate(to: ~p"/skills")}
  end

  # A save that went through: the stored skill, clean, at its own URL.
  defp saved(socket, skill) do
    renamed? = skill.name != socket.assigns.skill.name
    socket = socket |> load(skill) |> assign(page_title: skill.name)
    if renamed?, do: push_patch(socket, to: ~p"/skills/#{skill.name}"), else: socket
  end

  # A save against an older version: the text stays in the box, with what to do.
  defp refused_stale(socket, params),
    do: assign(socket, form: skill_form(params), dirty?: true, stale?: true)

  # The owner's text over `skill`'s version, so the next save writes over it.
  defp keep_text(socket, skill) do
    params = socket.assigns.form.params |> Map.put("version", Integer.to_string(skill.version))

    socket
    |> assign(skill: skill, form: skill_form(params), stale?: false)
    |> assign(dirty?: dirty?(skill, params))
  end

  defp deleted(socket),
    do: socket |> assign(leaving?: true) |> gone("#{socket.assigns.skill.name} was deleted.")

  ## What changed elsewhere

  @impl true
  def handle_info(_message, %{assigns: %{leaving?: true}} = socket), do: {:noreply, socket}

  def handle_info({:skills_changed, id}, %{assigns: %{skill: %Skill{id: id}}} = socket) do
    case Skills.get(id) do
      nil -> {:noreply, deleted(socket)}
      %Skill{} = skill -> {:noreply, socket |> load_scopes() |> follow_version(skill)}
    end
  end

  def handle_info({:projects_changed, _id}, %{assigns: %{skill: %Skill{}}} = socket),
    do: {:noreply, load_scopes(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # The stored skill against the one the form loaded: the same version
  # changes nothing (a toggle); a newer one replaces a clean form, and
  # shows the banner over a dirty one.
  defp follow_version(%{assigns: %{skill: loaded}} = socket, %Skill{version: version})
       when version == loaded.version,
       do: socket

  defp follow_version(%{assigns: %{dirty?: false}} = socket, skill), do: replace(socket, skill)
  defp follow_version(socket, _skill), do: assign(socket, stale?: true)

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} shell={@shell} socket={@socket} active={:skills}>
      <div class="h-full overflow-y-auto">
        <div class="blip-clear-y mx-auto w-full max-w-4xl px-4 py-8 sm:px-6">
          <.header>
            <span id="skill-heading" class={@skill && "font-mono text-[19px]"}>
              {title(@skill)}
            </span>
            <:subtitle>
              <.link
                id="skill-back"
                navigate={~p"/skills"}
                class="inline-flex items-center gap-1 transition hover:text-ink"
              >
                <.icon name="hero-arrow-left-micro" class="size-4" /> Skills
              </.link>
            </:subtitle>
            <:actions :if={@skill}>
              <.button
                id="skill-delete"
                size="sm"
                variant="danger"
                phx-click="delete"
                data-confirm={"Delete #{@skill.name}? Blip and threads can't load it any more."}
              >
                <.icon name="hero-trash-micro" class="size-4" /> Delete
              </.button>
            </:actions>
          </.header>
          <.meta :if={@skill} skill={@skill} />

          <section
            :if={@skill}
            id="skill-scopes-section"
            class="mt-6 rounded-2xl border border-line bg-surface p-5 shadow-xs"
          >
            <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
              <h2 class="text-[13px] font-semibold text-ink">Turned on for</h2>
              <p class="text-[12px] text-ink-faint">
                Agents there see its name and description, and load it when a task calls for it.
              </p>
            </div>
            <div class="mt-4 flex flex-col gap-4 sm:flex-row sm:gap-8">
              <div class="shrink-0">
                <h3 class="text-[11px] font-semibold tracking-wider text-ink-faint uppercase">
                  Assistant
                </h3>
                <div class="mt-2.5">
                  <.switch
                    id="skill-scope-blip"
                    on={@blip?}
                    label="Blip"
                    phx-click="scope"
                    phx-value-scope="blip"
                    phx-value-on={to_string(!@blip?)}
                  />
                </div>
              </div>
              <div class="min-w-0 flex-1">
                <h3 class="text-[11px] font-semibold tracking-wider text-ink-faint uppercase">
                  Projects
                </h3>
                <div
                  id="skill-scopes"
                  phx-update="stream"
                  class="mt-2.5 grid gap-x-6 gap-y-2.5 sm:grid-cols-2"
                >
                  <p id="skill-no-projects" class="hidden text-[13px] text-ink-faint only:block">
                    No projects yet.
                  </p>
                  <div :for={{dom_id, row} <- @streams.projects} id={dom_id} class="min-w-0">
                    <.switch
                      id={"skill-scope-#{row.id}"}
                      on={row.on?}
                      label={row.name}
                      phx-click="scope"
                      phx-value-scope={row.id}
                      phx-value-on={to_string(!row.on?)}
                      class="max-w-full"
                    />
                  </div>
                </div>
              </div>
            </div>
          </section>

          <.install_notes :if={@skill} notes={SkillText.notes(@skill.install_notes)} />

          <.banner :if={@stale?} id="skill-stale" tone="warn" icon="hero-arrow-path">
            This skill changed since you opened it.
            <:actions>
              <.button id="skill-reload" size="sm" phx-click="reload">Load the saved version</.button>
              <.button id="skill-keep" size="sm" variant="ghost" phx-click="keep">
                Keep my text
              </.button>
            </:actions>
          </.banner>

          <.guarded_form
            for={@form}
            id="skill-form"
            dirty={@dirty?}
            leave="Leave without saving? Your changes to this skill will be lost."
            phx-change="edit"
            phx-submit="save"
            class="mt-6 space-y-5"
          >
            <.input :if={@skill} field={@form[:version]} type="hidden" id="skill-version" />

            <div id={"skill-fields-#{@revision}"} class="space-y-5">
              <.input
                field={@form[:name]}
                id="skill-name"
                label="Name"
                placeholder="pdf-forms"
                hint="Lowercase letters, digits and hyphens. Agents load the skill by this name."
                autocomplete="off"
                spellcheck="false"
                class={[field_class(), "font-mono text-[13px]"]}
                phx-mounted={is_nil(@skill) && JS.focus()}
              />
              <.input
                field={@form[:description]}
                id="skill-description"
                type="textarea"
                rows="3"
                label="Description"
                placeholder="Fill in PDF forms. Use when the user asks to fill or flatten a PDF form."
                hint="When should an agent use it? Agents see this before they load the skill."
              />
            </div>

            <div class="space-y-1.5">
              <label for="skill-instructions" class="block text-[13px] font-medium text-ink-soft">
                Instructions
              </label>
              <div class="overflow-hidden rounded-2xl border border-line bg-surface shadow-xs transition focus-within:border-accent/60 focus-within:shadow-md focus-within:shadow-accent/10">
                <div class="flex items-center justify-between gap-3 border-b border-line bg-sunken/50 px-3 py-2">
                  <div
                    role="tablist"
                    class="flex items-center rounded-full border border-line bg-sunken p-0.5"
                  >
                    <.editor_tab id="skill-tab-write" tab="write" current={@tab}>Write</.editor_tab>
                    <.editor_tab id="skill-tab-preview" tab="preview" current={@tab}>
                      Preview
                    </.editor_tab>
                  </div>
                  <span class="flex items-center gap-1.5 text-[11.5px] text-ink-faint">
                    <.icon name="hero-document-text-micro" class="size-4" /> Markdown
                  </span>
                </div>

                <div
                  id={"skill-editor-#{@revision}"}
                  class={["px-4 pt-3 pb-3", @tab == "preview" && "hidden"]}
                >
                  <.input
                    field={@form[:instructions]}
                    id="skill-instructions"
                    type="textarea"
                    rows="20"
                    phx-debounce="400"
                    spellcheck="false"
                    placeholder="What should an agent do when it loads this skill? Steps, checks and examples. Markdown works here."
                    class="block min-h-[26rem] w-full resize-y bg-transparent font-mono text-[13px] leading-relaxed text-ink outline-none placeholder:text-ink-faint"
                  />
                </div>

                <div
                  :if={@tab == "preview"}
                  id="skill-preview"
                  class="markdown-body min-h-[26rem] px-5 py-4 text-ink-soft"
                >
                  <%= if String.trim(instructions(@form)) == "" do %>
                    <p class="text-[14px] text-ink-faint">Nothing to preview yet.</p>
                  <% else %>
                    {raw(Markdown.to_html(instructions(@form)))}
                  <% end %>
                </div>

                <div class="flex items-center justify-between gap-3 border-t border-line px-4 py-3">
                  <p class="text-[12.5px] leading-relaxed text-ink-faint">
                    <span
                      :if={@dirty?}
                      id="skill-dirty"
                      class="inline-flex items-center gap-1.5 text-ink-soft"
                    >
                      <.dot status={:warn} class="size-1.5" /> Unsaved changes
                    </span>
                    <span :if={!@dirty?}>
                      An agent reads all of this when it loads the skill.
                    </span>
                  </p>
                  <.button
                    type="submit"
                    variant="primary"
                    size="sm"
                    id="skill-save"
                    phx-disable-with="Saving..."
                  >
                    Save
                  </.button>
                </div>
              </div>
            </div>
          </.guarded_form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :skill, Skill, required: true

  # "Version 3. Installed from github.com/... on Oct 7, 2:00 PM." or "Version 3. Written here."
  defp meta(assigns) do
    ~H"""
    <p id="skill-meta" class="mt-2 text-[12.5px] leading-relaxed text-ink-faint">
      Version {@skill.version}.
      <%= case @skill.origin do %>
        <% "written" -> %>
          Written here.
        <% "fetched" when is_binary(@skill.source_url) -> %>
          Installed from
          <a
            id="skill-source"
            href={@skill.source_url}
            target="_blank"
            rel="noopener noreferrer"
            class="break-all text-ink-soft underline decoration-line-strong underline-offset-2 transition hover:text-ink hover:decoration-ink-faint"
          >{SkillText.place(@skill.source_url)}</a>
          on <.local_time id="skill-installed-at" at={@skill.inserted_at} />.
        <% _pasted -> %>
          Installed from a pasted SKILL.md on
          <.local_time id="skill-installed-at" at={@skill.inserted_at} />.
      <% end %>
    </p>
    """
  end

  attr :notes, :list, required: true

  # What install left out, as it said at install.
  defp install_notes(assigns) do
    ~H"""
    <section
      :if={@notes != []}
      id="skill-install-notes"
      class="mt-4 rounded-2xl border border-line bg-sunken/60 px-5 py-4"
    >
      <h2 class="flex items-center gap-2 text-[13px] font-semibold text-ink">
        <.icon name="hero-information-circle" class="size-4 text-ink-faint" /> Install notes
      </h2>
      <ul class="mt-2 space-y-1.5 pl-6 text-[13px] leading-relaxed text-ink-soft">
        <li :for={note <- @notes} class="list-disc marker:text-ink-faint">{note}</li>
      </ul>
    </section>
    """
  end
end
