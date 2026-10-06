defmodule PhotonWeb.ProjectNewLive do
  @moduledoc """
  Starting a project, at `/projects/new` (section 5.3 of
  `docs/plans/step-2-projects-and-threads.md`): a purpose, the only
  required field, and an optional name. `Photon.Projects.create/1` checks
  both and makes the slug.
  """

  use PhotonWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Start a project")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} shell={@shell} socket={@socket}>
      <div class="h-full overflow-y-auto">
        <div class="blip-clear-y mx-auto w-full max-w-2xl px-4 py-8 sm:px-6">
          <.header>
            <span id="project-new-heading">Start a project</span>
            <:subtitle>
              A purpose and some notes, for any body of work: a repo, a trip, a house.
            </:subtitle>
          </.header>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
