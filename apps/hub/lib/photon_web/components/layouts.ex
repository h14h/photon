defmodule PhotonWeb.Layouts do
  @moduledoc """
  The app shell: a sidebar with the overview, every node and its recent
  work, and settings; the page fills the rest. On small screens the sidebar
  folds into a drawer behind a top bar.

  Blip floats over all of it: `PhotonWeb.BlipLive`, rendered here once and
  sticky, so it and its conversation stay put while you move between pages.
  """
  use PhotonWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :shell, :map, required: true
  attr :socket, Phoenix.LiveView.Socket, required: true, doc: "the page's, to render Blip"
  attr :active, :any, default: nil, doc: ":overview, :nodes, :settings, or {:session, id}"

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
      <.nav_item
        navigate={~p"/"}
        icon="hero-squares-2x2"
        active={@active == :overview}
        id="nav-overview"
      >
        Overview
        <:trailing>
          <span :if={@shell.working != []} class="text-[11px] text-accent-strong tabular-nums">
            {length(@shell.working)} running
          </span>
        </:trailing>
      </.nav_item>
      <.nav_item
        navigate={~p"/nodes"}
        icon="hero-server-stack"
        active={@active == :nodes}
        id="nav-nodes"
      >
        Nodes
        <:trailing>
          <span class="text-[11px] tabular-nums text-ink-faint">
            {Enum.count(@shell.nodes, & &1.online)} online
          </span>
        </:trailing>
      </.nav_item>
    </nav>

    <div class="mt-5 flex min-h-0 flex-1 flex-col">
      <div class="flex items-center justify-between px-5 pb-1.5">
        <span class="text-[11px] font-semibold tracking-wider text-ink-faint uppercase">Machines</span>
        <.link
          navigate={~p"/nodes"}
          class="rounded p-0.5 text-ink-faint transition hover:bg-sunken hover:text-ink"
          title="Add a node"
        >
          <.icon name="hero-plus-micro" class="size-4" />
        </.link>
      </div>
      <div class="min-h-0 flex-1 space-y-3 overflow-y-auto px-2.5 pb-4">
        <p :if={@shell.nodes == []} class="px-2.5 py-2 text-[13px] leading-relaxed text-ink-faint">
          No machines yet.
          <.link navigate={~p"/nodes"} class="text-accent-strong underline underline-offset-2">Add one</.link>
          so Blip has somewhere to send work.
        </p>
        <div :for={node <- @shell.nodes} id={"side-node-#{node.id}"}>
          <div class="flex items-center gap-2 px-2.5 py-1 text-[13px]">
            <.dot status={if(node.online, do: :ok, else: :off)} />
            <span class={["truncate font-medium", !node.online && "text-ink-faint"]}>{node.id}</span>
          </div>
          <.link
            :for={s <- @shell.sessions |> Enum.filter(&(&1.node_id == node.id)) |> Enum.take(4)}
            navigate={~p"/sessions/#{s.id}"}
            id={"side-session-#{s.id}"}
            class={[
              "ml-3 flex items-center gap-2 rounded-md border-l border-line py-1 pr-2 pl-3 text-[13px] transition",
              @active == {:session, s.id} && "border-accent bg-accent-soft text-ink",
              @active != {:session, s.id} && "text-ink-soft hover:bg-sunken hover:text-ink"
            ]}
          >
            <span class="min-w-0 flex-1 truncate">{s.title}</span>
            <.session_badge status={s.status} />
          </.link>
        </div>
      </div>
    </div>

    <div class="shrink-0 border-t border-line p-2.5">
      <.link
        :if={@shell.chatgpt.state != :signed_in}
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
      <div class="mt-1 flex justify-end px-1"><.theme_toggle /></div>
    </div>
    """
  end

  attr :status, :string, required: true

  @spec session_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def session_badge(assigns) do
    ~H"""
    <span :if={@status == "running"} class="text-accent-strong" title="Working">
      <.spinner class="size-3.5" />
    </span>
    <span :if={@status == "pending"} class="text-ink-faint" title="Waiting for the node">
      <.icon name="hero-clock-micro" class="size-3.5" />
    </span>
    <span :if={@status in ["failed", "stopped"]} class="text-bad" title={String.capitalize(@status)}>
      <.icon name="hero-exclamation-circle-micro" class="size-3.5" />
    </span>
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
