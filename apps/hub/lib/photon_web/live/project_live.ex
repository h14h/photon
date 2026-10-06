defmodule PhotonWeb.ProjectLive do
  @moduledoc """
  A project's page, at `/projects/:slug` (section 5.4 of
  `docs/plans/step-2-projects-and-threads.md`): its name, folder and
  purpose, its threads and its context files.

  The project is read by its slug through `Photon.Projects`; an unknown
  slug goes back to `/` with a flash.
  """

  use PhotonWeb, :live_view

  alias Photon.Projects
  alias Photon.Projects.Project

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Projects.get_by_slug(slug) do
      %Project{} = project ->
        {:ok, assign(socket, page_title: project.name, project: project)}

      nil ->
        {:ok, gone(socket, "There's no project called #{slug}.")}
    end
  end

  defp gone(socket, message), do: socket |> put_flash(:error, message) |> push_navigate(to: ~p"/")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} shell={@shell} socket={@socket}>
      <div class="h-full overflow-y-auto">
        <div class="blip-clear-y mx-auto w-full max-w-4xl px-4 py-8 sm:px-6">
          <.header>
            <span id="project-name">{@project.name}</span>
            <:subtitle>
              <span id="project-folder">
                Folder <code class="font-mono text-ink">{@project.slug}</code>
                in each machine's workspace
              </span>
            </:subtitle>
          </.header>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
