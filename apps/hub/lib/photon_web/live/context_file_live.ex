defmodule PhotonWeb.ContextFileLive do
  @moduledoc """
  A project's context file (section 5.5 of
  `docs/plans/step-2-projects-and-threads.md`): `:new` at
  `/projects/:slug/files/new` makes one, `:edit` at
  `/projects/:slug/files/:name` shows and edits one.

  The project and the file are read through `Photon.Projects`; an unknown
  project or file goes back to `/` with a flash.
  """

  use PhotonWeb, :live_view

  alias Photon.Projects
  alias Photon.Projects.{ContextFile, Project}

  @impl true
  def mount(%{"slug" => slug} = params, _session, socket) do
    with {:ok, project} <- project(slug),
         {:ok, file} <- file(project, params, socket.assigns.live_action) do
      {:ok, assign(socket, page_title: title(project, file), project: project, file: file)}
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

  defp file(_project, _params, :new), do: {:ok, nil}

  defp file(project, %{"name" => name}, :edit) do
    case Projects.get_file(project.id, name) do
      %ContextFile{} = file -> {:ok, file}
      nil -> {:error, "There's no file called #{name} in #{project.name}."}
    end
  end

  defp title(project, nil), do: "New file in #{project.name}"
  defp title(project, file), do: "#{file.name} in #{project.name}"

  defp gone(socket, message), do: socket |> put_flash(:error, message) |> push_navigate(to: ~p"/")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} shell={@shell} socket={@socket}>
      <div class="h-full overflow-y-auto">
        <div class="blip-clear-y mx-auto w-full max-w-3xl px-4 py-8 sm:px-6">
          <.header>
            <span id="file-heading">{if @file, do: @file.name, else: "New file"}</span>
            <:subtitle>
              <.link
                id="file-project"
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
