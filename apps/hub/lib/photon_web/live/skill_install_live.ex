defmodule PhotonWeb.SkillInstallLive do
  @moduledoc """
  Installing a skill at `/skills/install` (section 6.5 of
  `docs/plans/step-3-skills-and-schedules.md`), from a link or a pasted
  SKILL.md.

  For now the page is its header, with the way back to the Skills page;
  the two forms and the preview come with the page's own task.

  Everything the shell passes on is ignored.
  """

  use PhotonWeb, :live_view

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: "Install a skill")}

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} shell={@shell} socket={@socket} active={:skills}>
      <div class="h-full overflow-y-auto">
        <div class="blip-clear-y mx-auto w-full max-w-3xl px-4 py-8 sm:px-6">
          <.header>
            <span id="install-heading">Install a skill</span>
            <:subtitle>
              <.link
                id="install-back"
                navigate={~p"/skills"}
                class="inline-flex items-center gap-1 transition hover:text-ink"
              >
                <.icon name="hero-arrow-left-micro" class="size-4" /> Skills
              </.link>
            </:subtitle>
          </.header>
          <p class="mt-4 max-w-2xl text-[14px] leading-relaxed text-ink-soft">
            From a SKILL.md, pasted here or at a link. Only its instructions come in, and it's off everywhere until you turn it on.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
