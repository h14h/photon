defmodule PhotonWeb.Layouts do
  @moduledoc """
  The app shell: a sidebar with Home, Activity, the projects and their
  threads, Machines, Skills and Settings; the page fills the rest. On
  small screens the sidebar folds into a drawer behind a top bar. The
  sidebar's data is `@shell`, kept current by `PhotonWeb.Shell`.

  Blip (`PhotonWeb.BlipLive`) is rendered here once and sticky, so it and
  its conversation stay put while you move between pages.
  """
  use PhotonWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :shell, :map, required: true
  attr :socket, Phoenix.LiveView.Socket, required: true, doc: "the page's, to render Blip"

  attr :active, :any,
    default: nil,
    doc:
      "the page in the sidebar: `:home`, `:activity`, `:nodes`, `:skills`, `:settings`, `{:project, slug}` or `{:thread, slug, id}` (which marks its project's row too)"

  slot :inner_block, required: true

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <div class="flex h-dvh overflow-hidden bg-canvas text-ink">
      <div
        id="sidebar-scrim"
        class="fixed inset-0 z-30 hidden bg-black/30 backdrop-blur-[2px] lg:hidden"
        phx-click={close_sidebar()}
      />
      <aside
        id="sidebar"
        class="fixed inset-y-0 left-0 z-40 hidden w-72 shrink-0 flex-col border-r border-line bg-surface lg:static lg:flex lg:w-64"
      >
        <.sidebar shell={@shell} active={@active} />
      </aside>

      <div id="app-main" class="flex min-w-0 flex-1 flex-col">
        <div class="flex h-12 shrink-0 items-center gap-2 border-b border-line bg-surface/80 px-3 backdrop-blur lg:hidden">
          <button
            id="open-sidebar"
            phx-click={open_sidebar()}
            class="rounded-lg p-1.5 text-ink-soft transition hover:bg-sunken"
            aria-label="Menu"
          >
            <.icon name="hero-bars-3" class="size-5" />
          </button>
          <.brand />
        </div>
        <main class="min-h-0 flex-1">{render_slot(@inner_block)}</main>
      </div>
    </div>
    {live_render(@socket, PhotonWeb.BlipLive, id: "blip", sticky: true)}
    <.flash_group flash={@flash} />
    """
  end

  defp open_sidebar do
    %JS{} |> JS.show(to: "#sidebar", display: "flex") |> JS.show(to: "#sidebar-scrim")
  end

  defp close_sidebar do
    %JS{} |> JS.hide(to: "#sidebar") |> JS.hide(to: "#sidebar-scrim")
  end

  defp brand(assigns) do
    ~H"""
    <.link navigate={~p"/"} class="group flex items-center gap-2">
      <span class="relative grid size-6 place-items-center">
        <span class="absolute inset-0 rounded-full bg-accent/25 blur-[6px] transition group-hover:bg-accent/40" />
        <span class="relative size-3 rounded-full bg-gradient-to-br from-accent to-accent-strong ring-2 ring-surface" />
      </span>
      <span class="text-[15px] font-semibold tracking-tight">Photon</span>
    </.link>
    """
  end

  attr :shell, :map, required: true
  attr :active, :any, default: nil

  defp sidebar(assigns) do
    ~H"""
    <div class="flex h-14 shrink-0 items-center justify-between px-4">
      <.brand />
      <button
        phx-click={close_sidebar()}
        class="rounded-lg p-1 text-ink-faint hover:bg-sunken lg:hidden"
      >
        <.icon name="hero-x-mark" class="size-5" />
      </button>
    </div>

    <nav class="space-y-0.5 px-2.5">
      <.nav_item navigate={~p"/"} icon="hero-home" active={@active == :home} id="nav-home">
        Home
        <:trailing>
          <span
            :if={@shell.needs_you > 0}
            id="nav-home-count"
            title={PhotonWeb.ThreadText.summary(@shell.needs_you)}
            class="min-w-5 rounded-full bg-warn-soft px-1.5 py-px text-center text-[11px] font-semibold tabular-nums text-ink"
          >
            {@shell.needs_you}
          </span>
        </:trailing>
      </.nav_item>
      <.nav_item
        navigate={~p"/activity"}
        icon="hero-queue-list"
        active={@active == :activity}
        id="nav-activity"
      >
        Activity
      </.nav_item>
    </nav>

    <div class="mt-5 flex min-h-0 flex-1 flex-col">
      <div class="flex items-center justify-between px-5 pb-1.5">
        <span class="text-[11px] font-semibold tracking-wider text-ink-faint uppercase">Projects</span>
        <.link
          navigate={~p"/projects/new"}
          id="new-project"
          class="rounded p-0.5 text-ink-faint transition hover:bg-sunken hover:text-ink"
          title="Start a project"
        >
          <.icon name="hero-plus-micro" class="size-4" />
        </.link>
      </div>
      <div id="side-projects" class="min-h-0 flex-1 space-y-1 overflow-y-auto px-2.5 pb-4">
        <p
          :if={@shell.projects == []}
          id="no-projects"
          class="px-2.5 py-2 text-[13px] leading-relaxed text-ink-faint"
        >
          No projects yet. A project is a purpose and some notes, for any body of work: a repo, a trip, a house.
          <.link
            navigate={~p"/projects/new"}
            id="start-first-project"
            class="text-accent-strong underline underline-offset-2"
          >
            Start one
          </.link>
        </p>
        <.side_project :for={entry <- @shell.projects} entry={entry} active={@active} />
      </div>
    </div>

    <div class="shrink-0 border-t border-line p-2.5">
      <%!-- Only while no model can answer: the scripted model counts. --%>
      <.link
        :if={!@shell.model_ready and @shell.chatgpt.state != :signed_in}
        navigate={~p"/settings"}
        id="sign-in-banner"
        class="mb-2 flex items-center gap-2 rounded-lg bg-warn-soft px-3 py-2 text-[12.5px] text-ink transition hover:brightness-95"
      >
        <.icon name="hero-key" class="size-4 text-warn" />
        {if(@shell.chatgpt.state == :sign_in_again,
          do: "Sign in to ChatGPT again",
          else: "Sign in with ChatGPT"
        )}
      </.link>
      <div class="space-y-0.5">
        <.nav_item
          navigate={~p"/nodes"}
          icon="hero-server-stack"
          active={@active == :nodes}
          id="nav-machines"
        >
          Machines
          <:trailing>
            <span class="flex items-center gap-1.5 text-[11px] tabular-nums text-ink-faint">
              <.dot :if={Enum.any?(@shell.nodes, & &1.online)} status={:ok} class="size-1.5" />
              {Enum.count(@shell.nodes, & &1.online)} online
            </span>
          </:trailing>
        </.nav_item>
        <.nav_item
          navigate={~p"/skills"}
          icon="hero-book-open"
          active={@active == :skills}
          id="nav-skills"
        >
          Skills
        </.nav_item>
        <.nav_item
          navigate={~p"/settings"}
          icon="hero-cog-6-tooth"
          active={@active == :settings}
          id="nav-settings"
        >
          Settings
          <:trailing>
            <span class="max-w-28 truncate text-[11px] text-ink-faint">{@shell.model}</span>
          </:trailing>
        </.nav_item>
      </div>
      <div class="mt-1 flex justify-end px-1"><.theme_toggle /></div>
    </div>
    """
  end

  attr :entry, :map, required: true, doc: "one of `Photon.Threads.sidebar/1`'s projects"
  attr :active, :any, default: nil

  # A project's row, with a "+" that starts a thread in it, then its
  # listed threads and how many more it has.
  defp side_project(assigns) do
    slug = assigns.entry.project.slug

    assigns =
      assign(assigns,
        slug: slug,
        here: assigns.active == {:project, slug},
        within: match?({:thread, ^slug, _id}, assigns.active)
      )

    ~H"""
    <div>
      <div class={[
        "group/project flex items-center rounded-lg transition",
        @here && "bg-sunken",
        !@here && "hover:bg-sunken"
      ]}>
        <.link
          navigate={~p"/projects/#{@slug}"}
          id={"side-project-#{@slug}"}
          aria-current={@here && "page"}
          class={[
            "flex min-w-0 flex-1 items-center gap-2.5 py-1.5 pl-2.5 text-sm transition",
            (@here or @within) && "font-medium text-ink",
            !(@here or @within) && "text-ink-soft group-hover/project:text-ink"
          ]}
        >
          <.icon
            name="hero-folder"
            class={[
              "size-[18px] shrink-0",
              if(@here or @within,
                do: "text-accent-strong",
                else: "text-ink-faint group-hover/project:text-ink-soft"
              )
            ]}
          />
          <span class="truncate">{@entry.project.name}</span>
        </.link>
        <.link
          navigate={~p"/projects/#{@slug}/threads/new"}
          id={"new-thread-#{@slug}"}
          title="Start a thread"
          aria-label={"Start a thread in #{@entry.project.name}"}
          class="mr-1 shrink-0 rounded p-1 text-ink-faint opacity-50 transition group-hover/project:opacity-100 hover:bg-line/60 hover:text-ink focus-visible:opacity-100"
        >
          <.icon name="hero-plus-micro" class="size-4" />
        </.link>
      </div>
      <div :if={@entry.threads != [] or @entry.more > 0} class="mt-0.5 space-y-px">
        <.link
          :for={thread <- @entry.threads}
          navigate={~p"/projects/#{@slug}/threads/#{thread.id}"}
          id={"side-thread-#{thread.id}"}
          data-running={thread.running? && "true"}
          data-state={thread.state}
          aria-current={@active == {:thread, @slug, thread.id} && "page"}
          class={[
            "flex items-center gap-2 rounded-lg py-1 pr-2.5 pl-9 text-[13px] transition",
            @active == {:thread, @slug, thread.id} && "bg-sunken font-medium text-ink",
            @active != {:thread, @slug, thread.id} && "text-ink-soft hover:bg-sunken hover:text-ink"
          ]}
          title={thread.title}
        >
          <span class="min-w-0 flex-1 truncate">{thread.title}</span>
          <.state_mark state={thread.state} class="size-3.5" />
        </.link>
        <.link
          :if={@entry.more > 0}
          navigate={~p"/projects/#{@slug}"}
          id={"side-more-#{@slug}"}
          class="block rounded-lg py-1 pr-2.5 pl-9 text-[12px] text-ink-faint transition hover:bg-sunken hover:text-ink-soft"
        >
          {@entry.more} more
        </.link>
      </div>
    </div>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, default: false
  attr :id, :string, required: true
  slot :inner_block, required: true
  slot :trailing

  defp nav_item(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      id={@id}
      aria-current={@active && "page"}
      class={[
        "group flex items-center gap-2.5 rounded-lg px-2.5 py-1.5 text-sm transition",
        @active && "bg-sunken font-medium text-ink",
        !@active && "text-ink-soft hover:bg-sunken hover:text-ink"
      ]}
    >
      <.icon
        name={@icon}
        class={[
          "size-[18px]",
          if(@active, do: "text-accent-strong", else: "text-ink-faint group-hover:text-ink-soft")
        ]}
      />
      <span class="flex-1">{render_slot(@inner_block)}</span>
      {render_slot(@trailing)}
    </.link>
    """
  end

  @doc "Shows the flash group with standard titles and content."
  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  @spec flash_group(map()) :: Phoenix.LiveView.Rendered.t()
  def flash_group(assigns) do
    ~H"""
    <div
      id={@id}
      aria-live="polite"
      class="pointer-events-none fixed top-3 right-3 z-50 flex flex-col gap-2"
    >
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="Lost the connection"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Reconnecting <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Reconnecting <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc "Light, dark, or follow the system."
  @spec theme_toggle(map()) :: Phoenix.LiveView.Rendered.t()
  def theme_toggle(assigns) do
    ~H"""
    <div class="flex items-center rounded-full border border-line bg-sunken p-0.5">
      <button
        :for={
          {theme, icon} <- [
            {"system", "hero-computer-desktop-micro"},
            {"light", "hero-sun-micro"},
            {"dark", "hero-moon-micro"}
          ]
        }
        class={[
          "rounded-full p-1 text-ink-faint transition hover:text-ink",
          "[[data-theme-source=system]_&]:data-[phx-theme=system]:bg-surface [[data-theme-source=system]_&]:data-[phx-theme=system]:text-ink",
          "[[data-theme-source=user][data-theme=light]_&]:data-[phx-theme=light]:bg-surface [[data-theme-source=user][data-theme=light]_&]:data-[phx-theme=light]:text-ink",
          "[[data-theme-source=user][data-theme=dark]_&]:data-[phx-theme=dark]:bg-surface [[data-theme-source=user][data-theme=dark]_&]:data-[phx-theme=dark]:text-ink"
        ]}
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme={theme}
        title={"#{String.capitalize(theme)} theme"}
      >
        <.icon name={icon} class="size-3.5" />
      </button>
    </div>
    """
  end
end
