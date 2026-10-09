defmodule PhotonWeb.SkillLive do
  @moduledoc """
  One skill: `:new` at `/skills/new` writes one, `:edit` at `/skills/:name`
  shows, edits and turns one on.

  The editor is a form over a plain map (`name`, `description`,
  `instructions` and, when editing, the hidden `version` it loaded).
  `Photon.Skills` checks it and the version on save. A save that renames
  the skill patches the URL to the new name. The form asks before the
  owner leaves it with unsaved text
  (`PhotonWeb.EditorComponents.guarded_form/1`).

  "Turned on for" has a switch for Blip, one per project and one per
  machine the hub knows (`Photon.Machines.known/0`). Each switch calls
  `Skills.enable/2` or `disable/2` with the state it should end in, so a
  double click or a stale page can't flip it the wrong way; a refused
  enable (30 on already, or a machine removed since the page loaded) is a
  flash.

  A toggle and a save announce the same `{:skills_changed, id}`
  (`Skills.subscribe/0`), so for the open skill the page always re-reads
  where the skill is on, and only when the stored version differs from
  the one the form loaded does a clean form load it (following a rename),
  or a dirty one keep the owner's text and show `#skill-stale`. `Keep my
  text` takes the stored version's number, so the next save writes over
  it. A save with an old version (`:stale`) shows the same banner. When
  the text is replaced from the server, the fields get new DOM IDs
  (`@revision`), because LiveView leaves a focused field's value alone. A
  deleted skill sends the page to `/skills`.

  `{:projects_changed, _}`, `:nodes_changed` and `{:node_keys_changed, _}`
  (through `PhotonWeb.Shell`) re-read the projects or machines, so the
  switches keep up. Everything else the shell passes on is ignored. An
  unknown skill goes back to `/skills` with a flash.
  """

  use PhotonWeb, :live_view

  import PhotonWeb.EditorComponents
  import PhotonWeb.SkillComponents

  alias Photon.{Machines, Projects, Skills}
  alias Photon.Skills.Skill
  alias PhotonWeb.{FormParams, SkillText}

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
         |> stream_configure(:machines, dom_id: &"skill-machine-row-#{&1.id}")
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

  # Where the open skill is on: Blip's switch, one per project by name,
  # and one per known machine in `Machines.known/0`'s order.
  defp load_scopes(%{assigns: %{skill: nil}} = socket) do
    socket
    |> assign(blip?: false)
    |> stream(:projects, [], reset: true)
    |> stream(:machines, [], reset: true)
  end

  defp load_scopes(%{assigns: %{skill: skill}} = socket) do
    scopes = Skills.scopes(skill.id)

    projects =
      for p <- Projects.list(), do: %{id: p.id, name: p.name, on?: {:project, p.id} in scopes}

    machines = for id <- Machines.known(), do: %{id: id, on?: {:machine, id} in scopes}

    socket
    |> assign(blip?: :blip in scopes)
    |> stream(:projects, projects, reset: true)
    |> stream(:machines, machines, reset: true)
  end

  # The form over `params`, with the context's `%{field => message}` errors.
  defp skill_form(params, errors \\ %{}), do: FormParams.form(params, :skill, errors)

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
    params = FormParams.clean(params)

    {:noreply,
     assign(socket, form: skill_form(params), dirty?: dirty?(socket.assigns.skill, params))}
  end

  def handle_event("tab", %{"tab" => tab}, socket) when tab in ["write", "preview"],
    do: {:noreply, assign(socket, tab: tab)}

  def handle_event("save", %{"skill" => params}, %{assigns: %{live_action: :new}} = socket) do
    params = FormParams.clean(params)

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
    params = FormParams.clean(params)

    case Skills.update(socket.assigns.skill.id, params, FormParams.version(params)) do
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

  def handle_event("scope", %{"machine" => machine, "on" => on}, socket),
    do: {:noreply, toggle(socket, {:machine, machine}, on == "true")}

  def handle_event("scope", %{"scope" => scope, "on" => on}, socket) do
    scope = if scope == "blip", do: :blip, else: {:project, scope}
    {:noreply, toggle(socket, scope, on == "true")}
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

  # Turns the open skill on or off for `scope`, then shows where it is on.
  defp toggle(%{assigns: %{skill: %Skill{id: id}}} = socket, scope, on?) do
    case if(on?, do: Skills.enable(id, scope), else: Skills.disable(id, scope)) do
      :ok -> load_scopes(socket)
      {:error, :not_found} -> deleted(socket)
      {:error, message} -> socket |> put_flash(:error, message) |> load_scopes()
    end
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

  # A machine installed, removed or (for `local`) connected: the known
  # machines may have changed, so the switches are read again.
  def handle_info(:nodes_changed, %{assigns: %{skill: %Skill{}}} = socket),
    do: {:noreply, load_scopes(socket)}

  def handle_info({:node_keys_changed, _id}, %{assigns: %{skill: %Skill{}}} = socket),
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
            <div class="mt-4 flex flex-col gap-4 xl:flex-row xl:gap-8">
              <div class="flex min-w-0 flex-1 flex-col gap-4 sm:flex-row sm:gap-8">
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
              <div class="min-w-0 xl:w-52 xl:shrink-0">
                <h3 class="text-[11px] font-semibold tracking-wider text-ink-faint uppercase">
                  Machines
                </h3>
                <div
                  id="skill-machine-scopes"
                  phx-update="stream"
                  class="mt-2.5 grid gap-x-6 gap-y-2.5 sm:grid-cols-2 xl:grid-cols-1"
                >
                  <p id="skill-no-machines" class="hidden text-[13px] text-ink-faint only:block">
                    No machines yet.
                  </p>
                  <div :for={{dom_id, row} <- @streams.machines} id={dom_id} class="min-w-0">
                    <.switch
                      id={"skill-scope-machine-#{row.id}"}
                      on={row.on?}
                      label={row.id}
                      phx-click="scope"
                      phx-value-machine={row.id}
                      phx-value-on={to_string(!row.on?)}
                      class="max-w-full"
                    />
                  </div>
                </div>
                <p id="skill-machines-hint" class="mt-2.5 text-[11.5px] text-ink-faint">
                  For Blip and every thread, when they work there.
                </p>
              </div>
            </div>
          </section>

          <%!-- What install left out, as it said at install. --%>
          <.install_notes
            :if={@skill}
            id="skill-install-notes"
            notes={SkillText.notes(@skill.install_notes)}
            heading="h2"
            class="mt-4"
          />

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
              <.markdown_editor
                id="skill"
                field={@form[:instructions]}
                tab={@tab}
                input_id="skill-instructions"
                editor_id={"skill-editor-#{@revision}"}
                preview_id="skill-preview"
                rows="20"
                min_height="min-h-[26rem]"
                placeholder="What should an agent do when it loads this skill? Steps, checks and examples. Markdown works here."
              >
                <:footer>
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
                </:footer>
              </.markdown_editor>
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
end
