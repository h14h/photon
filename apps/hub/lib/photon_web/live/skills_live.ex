defmodule PhotonWeb.SkillsLive do
  @moduledoc """
  The Skills page at `/skills` (section 6.3 of
  `docs/plans/step-3-skills-and-schedules.md`): every skill on this hub,
  where each is on, how it arrived, and a switch per skill for Blip, with
  the two ways to add one, writing it here (`/skills/new`) or installing
  it from a SKILL.md or a link (`/skills/install`). A new skill is off
  everywhere until the owner turns it on for Blip, a project or a machine.

  The skills are a stream (`#skills`, rows `#skill-<id>`) read from
  `Photon.Skills.list/0` together with the projects' names for the scopes
  line. The page follows `Skills.subscribe/0` and re-reads the list on
  every `{:skills_changed, _}`: a skill written, installed, saved or
  deleted anywhere, or turned on or off here, on its own page or on a
  project's. `{:projects_changed, id}` (through `PhotonWeb.Shell`)
  re-reads it only when a listed skill is on in that project, so a
  rename shows and a busy project's thread messages don't (rule 73).
  `{:node_keys_changed, _}` (also through the shell) re-reads it on every
  machine installed or removed, so a removed machine drops out of the
  scopes lines (section 6.2 of `docs/plans/machine-skills.md`); removals
  are rare, so it doesn't check which skills name the machine.

  The Blip switch sends the state it should end in, so a double click or
  a stale page can't flip it the wrong way; a refused enable (30 on
  already) is a flash. Everything else the shell passes on is ignored.
  """

  use PhotonWeb, :live_view

  alias Photon.{Projects, Skills}
  alias PhotonWeb.SkillText

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :ok = Skills.subscribe()

    {:ok,
     socket
     |> assign(page_title: "Skills")
     |> stream_configure(:skills, dom_id: &"skill-#{&1.id}")
     |> load()}
  end

  # Every skill with its scopes line and origin, and the projects the
  # lines name, so a rename of one of them redraws the list.
  defp load(socket) do
    names = Map.new(Projects.list(), &{&1.id, &1.name})
    listed = Skills.list()

    projects =
      for %{scopes: scopes} <- listed, {:project, id} <- scopes, into: MapSet.new(), do: id

    socket
    |> assign(project_ids: projects)
    |> stream(:skills, Enum.map(listed, &row(&1, names)), reset: true)
  end

  defp row(%{id: id, skill: skill, scopes: scopes}, names) do
    %{
      id: id,
      skill: skill,
      blip?: :blip in scopes,
      on?: scopes != [],
      scopes: SkillText.scopes(scopes, names),
      origin: SkillText.origin(skill)
    }
  end

  @impl true
  def handle_event("blip", %{"id" => id, "on" => on}, socket) do
    result = if on == "true", do: Skills.enable(id, :blip), else: Skills.disable(id, :blip)

    case result do
      :ok ->
        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, socket |> put_flash(:error, "That skill was deleted.") |> load()}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_info({:skills_changed, _id}, socket), do: {:noreply, load(socket)}

  def handle_info({:node_keys_changed, _id}, socket), do: {:noreply, load(socket)}

  def handle_info({:projects_changed, id}, socket) do
    if MapSet.member?(socket.assigns.project_ids, id),
      do: {:noreply, load(socket)},
      else: {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} shell={@shell} socket={@socket} active={:skills}>
      <div class="h-full overflow-y-auto">
        <div class="blip-clear-y mx-auto w-full max-w-3xl px-4 py-8 sm:px-6">
          <.header>
            <span id="skills-heading">Skills</span>
            <:subtitle>
              Instructions an agent loads when a task calls for them. A new skill is off everywhere until you turn it on for Blip, a project or a machine.
            </:subtitle>
            <:actions>
              <.button id="install-skill" size="sm" navigate={~p"/skills/install"}>
                <.icon name="hero-arrow-down-tray-micro" class="size-4" /> Install
              </.button>
              <.button id="new-skill" size="sm" variant="primary" navigate={~p"/skills/new"}>
                <.icon name="hero-pencil-square-micro" class="size-4" /> Write a skill
              </.button>
            </:actions>
          </.header>

          <div id="skills" phx-update="stream" class="mt-8 space-y-2.5">
            <div
              id="no-skills"
              class="hidden rounded-2xl border border-dashed border-line-strong px-6 py-10 text-center only:block"
            >
              <span class="mx-auto flex size-10 items-center justify-center rounded-full bg-accent-soft text-accent-strong">
                <.icon name="hero-book-open" class="size-5" />
              </span>
              <p class="mx-auto mt-3 max-w-sm text-[14px] leading-relaxed text-ink-soft">
                No skills yet. Write one, or install one from a SKILL.md or a GitHub link.
              </p>
            </div>
            <article
              :for={{dom_id, row} <- @streams.skills}
              id={dom_id}
              class="group rounded-xl border border-line bg-surface px-4 py-3.5 shadow-xs transition hover:border-line-strong"
            >
              <div class="flex items-start gap-3">
                <.icon
                  name="hero-book-open"
                  class="mt-0.5 size-4 shrink-0 text-ink-faint transition group-hover:text-ink-soft"
                />
                <div class="min-w-0 flex-1">
                  <div class="flex items-start justify-between gap-4">
                    <.link
                      id={"#{dom_id}-link"}
                      navigate={~p"/skills/#{row.skill.name}"}
                      class="min-w-0 truncate font-mono text-[13.5px] font-medium text-ink transition hover:text-accent-strong"
                    >
                      {row.skill.name}
                    </.link>
                    <.switch
                      id={"#{dom_id}-blip"}
                      on={row.blip?}
                      label="Blip"
                      phx-click="blip"
                      phx-value-id={row.id}
                      phx-value-on={to_string(!row.blip?)}
                      aria-label={"Blip can use #{row.skill.name}"}
                      class="shrink-0"
                    />
                  </div>
                  <p class="mt-1 line-clamp-2 text-[13.5px] leading-relaxed text-ink-soft">
                    {row.skill.description}
                  </p>
                  <p class="mt-2 flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 text-[12px] text-ink-faint">
                    <span
                      id={"#{dom_id}-scopes"}
                      class={[
                        "inline-flex items-center gap-1.5",
                        row.on? && "text-ink-soft"
                      ]}
                    >
                      <.dot status={if row.on?, do: :ok, else: :off} class="size-1.5" />
                      {row.scopes}
                    </span>
                    <span aria-hidden="true">·</span>
                    <span id={"#{dom_id}-origin"} class="min-w-0 truncate">{row.origin}</span>
                  </p>
                </div>
              </div>
            </article>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
