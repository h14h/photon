defmodule PhotonWeb.ProjectNewLive do
  @moduledoc """
  Starting a project, at `/projects/new`: a purpose, the only required
  field, and an optional name. `Photon.Projects.create/1` checks both and
  makes the slug; its errors show under their fields, and a new project
  opens on its own page.

  The form is a plain map (`to_form/2` with `as: :project`), since no
  changeset leaves the context. Typing clears the errors of the last try.
  """

  use PhotonWeb, :live_view

  alias Photon.Projects

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Start a project", form: project_form(%{}))}
  end

  @impl true
  def handle_event("change", %{"project" => params}, socket),
    do: {:noreply, assign(socket, form: project_form(params))}

  def handle_event("create", %{"project" => params}, socket) do
    case Projects.create(params) do
      {:ok, project} -> {:noreply, push_navigate(socket, to: ~p"/projects/#{project.slug}")}
      {:error, errors} -> {:noreply, assign(socket, form: project_form(params, errors))}
    end
  end

  # The form over `params`, with the context's `%{field => message}` errors.
  defp project_form(params, errors \\ %{}),
    do: to_form(params, as: :project, errors: Enum.map(errors, fn {k, v} -> {k, {v, []}} end))

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

          <.form
            for={@form}
            id="project-form"
            phx-change="change"
            phx-submit="create"
            class="mt-8 space-y-5 rounded-2xl border border-line bg-surface p-5 shadow-xs"
          >
            <.input
              field={@form[:purpose]}
              id="project-purpose-input"
              type="textarea"
              rows="5"
              label="Purpose"
              placeholder="What is this project for? A few sentences."
              hint="Every thread in this project sees it, so say what the work is and what it should know."
              phx-mounted={JS.focus()}
            />
            <.input
              field={@form[:name]}
              id="project-name-input"
              label="Name"
              hint="Optional. Made from the purpose if you leave it blank."
              autocomplete="off"
            />
            <div class="flex items-center justify-between gap-3 border-t border-line pt-4">
              <p class="text-[12.5px] leading-relaxed text-ink-faint">
                The project gets a folder named after it in each machine's workspace.
              </p>
              <.button
                type="submit"
                variant="primary"
                id="project-create"
                phx-disable-with="Starting..."
              >
                Start project
              </.button>
            </div>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
