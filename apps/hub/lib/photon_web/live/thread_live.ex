defmodule PhotonWeb.ThreadLive do
  @moduledoc """
  A project's thread (sections 5.6 and 5.7 of
  `docs/plans/step-2-projects-and-threads.md`): `:new` at
  `/projects/:slug/threads/new` starts one with its first message, `:show`
  at `/projects/:slug/threads/:id` is its conversation.

  The project and the thread are read through `Photon.Projects` and
  `Photon.Threads`. An unknown project or thread, or a thread under
  another project's slug, goes back to `/` with a flash.
  """

  use PhotonWeb, :live_view

  alias Photon.{Projects, Threads}
  alias Photon.Projects.Project
  alias Photon.Threads.Thread

  @impl true
  def mount(%{"slug" => slug} = params, _session, socket) do
    with {:ok, project} <- project(slug),
         {:ok, thread} <- thread(project, params, socket.assigns.live_action) do
      {:ok, assign(socket, page_title: title(project, thread), project: project, thread: thread)}
    else
      {:error, message} -> {:ok, gone(socket, message)}
    end
  end

  defp project(slug) do
    case Projects.get_by_slug(slug) do
      %Project{} = project -> {:ok, project}
      nil -> {:error, "There's no project called #{slug}."}
    end
  end

  defp thread(_project, _params, :new), do: {:ok, nil}

  defp thread(project, %{"id" => id}, :show) do
    case Threads.get(id) do
      %Thread{project_id: project_id} = thread when project_id == project.id -> {:ok, thread}
      _missing -> {:error, "There's no such thread in #{project.name}."}
    end
  end

  defp title(project, nil), do: "New thread in #{project.name}"
  defp title(_project, thread), do: thread.title

  defp active(project, nil), do: {:project, project.slug}
  defp active(project, thread), do: {:thread, project.slug, thread.id}

  defp gone(socket, message), do: socket |> put_flash(:error, message) |> push_navigate(to: ~p"/")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} shell={@shell} socket={@socket} active={active(@project, @thread)}>
      <div class="h-full overflow-y-auto">
        <div class="blip-clear-y mx-auto w-full max-w-3xl px-4 py-8 sm:px-6">
          <.header>
            <span :if={@thread} id="thread-title">{@thread.title}</span>
            <span :if={!@thread} id="thread-new-heading">New thread in {@project.name}</span>
            <:subtitle>
              <.link
                id="thread-project"
                navigate={~p"/projects/#{@project.slug}"}
                class="hover:text-ink"
              >
                {@project.name}
              </.link>
            </:subtitle>
          </.header>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
