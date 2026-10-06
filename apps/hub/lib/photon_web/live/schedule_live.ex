defmodule PhotonWeb.ScheduleLive do
  @moduledoc """
  A project's schedule (section 6.7 of
  `docs/plans/step-3-skills-and-schedules.md`): `:new` at
  `/projects/:slug/schedules/new` makes one, `:edit` at
  `/projects/:slug/schedules/:id` shows and edits one.

  For now the page is its header ("New schedule", or "Schedule" with its
  prompt under it) and the way back to the project. The form comes with
  the page's own task.

  An unknown project or schedule, or a schedule under another project's
  slug (or one of Blip's), goes back to `/` with a flash, as the thread
  and file pages do. Everything the shell passes on is ignored.
  """

  use PhotonWeb, :live_view

  alias Photon.{Projects, Schedules}
  alias Photon.Projects.Project

  @impl true
  def mount(%{"slug" => slug} = params, _session, socket) do
    with {:ok, project} <- project(slug),
         {:ok, schedule} <- schedule(project, params, socket.assigns.live_action) do
      {:ok,
       assign(socket,
         project: project,
         schedule: schedule,
         page_title: title(project, schedule)
       )}
    else
      {:error, message} ->
        {:ok, socket |> put_flash(:error, message) |> push_navigate(to: ~p"/")}
    end
  end

  defp project(slug) do
    case Projects.get_by_slug(slug) do
      %Project{} = project -> {:ok, project}
      nil -> {:error, "There's no project called #{slug}."}
    end
  end

  defp schedule(_project, _params, :new), do: {:ok, nil}

  defp schedule(project, %{"id" => id}, :edit) do
    case Schedules.get(id) do
      %{schedule: %{project_id: project_id} = schedule} when project_id == project.id ->
        {:ok, schedule}

      _missing ->
        {:error, "There's no such schedule in #{project.name}."}
    end
  end

  defp title(project, nil), do: "New schedule in #{project.name}"
  defp title(project, _schedule), do: "Schedule in #{project.name}"

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      shell={@shell}
      socket={@socket}
      active={{:project, @project.slug}}
    >
      <div class="h-full overflow-y-auto">
        <div class="blip-clear-y mx-auto w-full max-w-2xl px-4 py-8 sm:px-6">
          <.header>
            <span id="schedule-heading">
              {if @schedule, do: "Schedule", else: "New schedule"}
            </span>
            <:subtitle>
              <.link
                id="schedule-project"
                navigate={~p"/projects/#{@project.slug}"}
                class="inline-flex items-center gap-1 transition hover:text-ink"
              >
                <.icon name="hero-arrow-left-micro" class="size-4" /> {@project.name}
              </.link>
            </:subtitle>
          </.header>
          <p
            :if={@schedule}
            id="schedule-summary"
            class="mt-4 line-clamp-4 rounded-2xl border border-line bg-surface p-4 text-[14px] leading-relaxed whitespace-pre-line text-ink shadow-xs"
          >
            {@schedule.prompt}
          </p>
          <p :if={!@schedule} class="mt-4 text-[14px] leading-relaxed text-ink-soft">
            A schedule starts a thread in {@project.name}, or wakes one, at set times.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
