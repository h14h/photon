defmodule PhotonWeb.SkillsLive do
  @moduledoc """
  The Skills page at `/skills` (section 6.3 of
  `docs/plans/step-3-skills-and-schedules.md`): the skills on this hub,
  with the two ways to add one, writing it here (`/skills/new`) or
  installing it from a SKILL.md or a link (`/skills/install`).

  For now the page is its header and those two links; the list of skills
  and the Blip switch come with the page's own task.

  Everything the shell passes on is ignored.
  """

  use PhotonWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: "Skills")}

  @impl true
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
              Instructions an agent loads when a task calls for them. A new skill is off everywhere until you turn it on for Blip or a project.
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
        </div>
      </div>
    </Layouts.app>
    """
  end
end
