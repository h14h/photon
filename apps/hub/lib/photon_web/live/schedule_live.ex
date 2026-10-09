defmodule PhotonWeb.ScheduleLive do
  @moduledoc """
  A project's schedule: `:new` at `/projects/:slug/schedules/new` makes one,
  `:edit` at `/projects/:slug/schedules/:id` shows and edits one.

  The form (`#schedule-form`) is a plain map with string keys, as
  `Photon.Schedules.new_params/1` and `edit_params/1` give it: the
  prompt, the first time (the hidden UTC field behind
  `local_datetime_input/1`, which the browser fills from the owner's local
  time), Once or Every with the interval, and the thread (a new one each
  time, or one of the project's by last activity). `?thread=<id>` on
  `:new` picks that thread. Saving hands it to `Photon.Schedules`, which
  checks it; its errors show under their fields, and a saved schedule
  returns to the project page. The form asks before the owner leaves it
  with unsaved changes (`PhotonWeb.EditorComponents.guarded_form/1`).

  `:edit` also shows when the schedule runs next and what its last run
  did (`#schedule-next`, `#schedule-last`), with Run now and Delete. The
  form carries the version it loaded in a hidden field and saves with
  `Schedules.update/3`, so a save over an edit made in another tab is
  refused (`:stale`) and shows `#schedule-stale`, keeping what was typed,
  with `Load the saved version` and `Keep my text` (takes the stored
  version's number, so the next save writes over it), as the skill
  editor does.

  On `:edit` the page follows `Schedules.subscribe/0`. A firing, a Run now
  and a failure announce `{:schedules_changed, project_id}` as edits do,
  and a five-minute schedule fires every five minutes, so the handler
  never touches the form: it re-reads the schedule and refreshes only the
  next and last run, and shows `#schedule-stale` when the version moved.
  A schedule deleted elsewhere sends the page back to the project.

  `{:projects_changed, id}` for the project (through `PhotonWeb.Shell`)
  re-reads the project and its threads, so a new or renamed thread shows
  in the thread list and the last run's line. Everything else the shell
  passes on is ignored.

  An unknown project or schedule, or a schedule under another project's
  slug (or one of Blip's), goes back to `/` with a flash, as the thread
  and file pages do.
  """

  use PhotonWeb, :live_view

  import PhotonWeb.EditorComponents
  import PhotonWeb.ScheduleComponents

  alias Photon.{Projects, Schedules, Threads}
  alias Photon.Projects.Project
  alias Photon.Schedules.Schedule
  alias PhotonWeb.ScheduleText

  @units [{"minutes", "minute"}, {"hours", "hour"}, {"days", "day"}, {"weeks", "week"}]

  @impl true
  def mount(%{"slug" => slug} = params, _session, socket) do
    with {:ok, project} <- project(slug),
         {:ok, item} <- schedule(project, params, socket.assigns.live_action) do
      if item && connected?(socket), do: :ok = Schedules.subscribe()

      {:ok, socket |> start(project, item) |> open(item, params["thread"])}
    else
      {:error, message} -> {:ok, gone(socket, ~p"/", message)}
    end
  end

  defp start(socket, project, item) do
    socket
    |> assign(project: project, revision: 0, leaving?: false)
    |> assign(page_title: title(project, item))
    |> load_threads()
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
      %{schedule: %Schedule{project_id: project_id}} = item when project_id == project.id ->
        {:ok, item}

      _missing ->
        {:error, "There's no such schedule in #{project.name}."}
    end
  end

  defp title(project, nil), do: "New schedule in #{project.name}"
  defp title(project, _item), do: "Schedule in #{project.name}"

  defp gone(socket, to, message),
    do: socket |> assign(leaving?: true) |> put_flash(:error, message) |> push_navigate(to: to)

  ## The form's state

  # The project's threads, most recently active first: the thread list.
  defp load_threads(socket), do: assign(socket, threads: Threads.list(socket.assigns.project.id))

  # A new schedule's form at the next whole hour, on the thread `?thread=`
  # names when it is one of the project's.
  defp open(socket, nil, thread_id) do
    params = Schedules.new_params(DateTime.utc_now())

    params =
      if Enum.any?(socket.assigns.threads, &(&1.id == thread_id)),
        do: Map.put(params, "target", thread_id),
        else: params

    socket
    |> assign(schedule: nil, item: nil, titles: %{}, stale?: false)
    |> loaded(params)
  end

  defp open(socket, item, _thread_id), do: socket |> with_item(item) |> load(item.schedule)

  # The stored schedule in a clean form, with the version it loaded.
  defp load(socket, %Schedule{} = schedule) do
    params =
      schedule
      |> Schedules.edit_params()
      |> Map.put("version", Integer.to_string(schedule.version))

    socket
    |> assign(schedule: schedule, stale?: false)
    |> loaded(params)
  end

  defp loaded(socket, params) do
    assign(socket, form: schedule_form(params), initial: normal(params), dirty?: false)
  end

  # When the schedule runs next and what its last run did, with the titles
  # of the threads those lines name.
  defp with_item(socket, item) do
    ids = for id <- [item.schedule.conversation_id, item.schedule.last_thread_id], id, do: id
    assign(socket, item: item, titles: Threads.titles(ids))
  end

  # The form over `params`, with the context's `%{field => message}` errors.
  defp schedule_form(params, errors \\ %{}),
    do: to_form(params, as: :schedule, errors: Enum.map(errors, fn {k, v} -> {k, {v, []}} end))

  # What a save would keep, to tell a changed form from the one loaded: the
  # trimmed prompt, the time as an instant (the browser writes it in its
  # own format), and the interval only when it repeats.
  defp normal(params) do
    repeat = params["repeat"]

    %{
      prompt: (params["prompt"] || "") |> String.replace("\r\n", "\n") |> String.trim(),
      at: instant(params["at"]),
      repeat: repeat,
      every: if(repeat == "every", do: {String.trim(params["every"] || ""), params["unit"]}),
      target: params["target"]
    }
  end

  defp instant(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
      {:error, _reason} -> at
    end
  end

  defp instant(at), do: at

  defp version(params) do
    case Integer.parse(Map.get(params, "version", "")) do
      {version, ""} when version > 0 -> version
      _other -> 0
    end
  end

  ## Events

  @impl true
  def handle_event("validate", %{"schedule" => params}, socket) do
    {:noreply,
     assign(socket, form: schedule_form(params), dirty?: normal(params) != socket.assigns.initial)}
  end

  def handle_event("save", %{"schedule" => params}, socket) do
    case save(socket, params) do
      {:ok, _schedule} ->
        {:noreply, back(socket, "Schedule saved.")}

      {:error, :stale} ->
        {:noreply, assign(socket, form: schedule_form(params), dirty?: true, stale?: true)}

      {:error, :not_found} ->
        {:noreply, missing(socket)}

      {:error, errors} ->
        {:noreply, assign(socket, form: schedule_form(params, errors))}
    end
  end

  def handle_event("reload", _params, socket) do
    case Schedules.get(socket.assigns.schedule.id) do
      nil ->
        {:noreply, deleted(socket)}

      item ->
        {:noreply,
         socket |> with_item(item) |> load(item.schedule) |> update(:revision, &(&1 + 1))}
    end
  end

  def handle_event("keep", _params, socket) do
    case Schedules.get(socket.assigns.schedule.id) do
      nil -> {:noreply, deleted(socket)}
      item -> {:noreply, socket |> with_item(item) |> keep_text(item.schedule)}
    end
  end

  def handle_event("run", _params, socket) do
    %Schedule{id: id, conversation_id: thread_id} = socket.assigns.schedule

    case Schedules.run_now(id) do
      {:ok, outcome} ->
        title = thread_id && socket.assigns.titles[thread_id]
        {:noreply, socket |> put_flash(:info, ScheduleText.ran(outcome, title)) |> refresh()}

      {:error, :not_found} ->
        {:noreply, deleted(socket)}
    end
  end

  def handle_event("delete", _params, socket) do
    # Deleted now or already gone: either way the schedule isn't there to show.
    _ = Schedules.delete(socket.assigns.schedule.id)

    {:noreply, back(socket, "Schedule deleted.")}
  end

  # Done here: back to the project page, saying what happened.
  defp back(socket, message) do
    socket
    |> assign(leaving?: true)
    |> put_flash(:info, message)
    |> push_navigate(to: ~p"/projects/#{socket.assigns.project.slug}")
  end

  defp save(%{assigns: %{schedule: nil, project: project}}, params),
    do: Schedules.create({:project, project.id}, params)

  defp save(%{assigns: %{schedule: schedule}}, params),
    do: Schedules.update(schedule.id, params, version(params))

  # A save that found nothing: a new schedule's project is gone, or the
  # schedule was deleted.
  defp missing(%{assigns: %{schedule: nil, project: project}} = socket),
    do: gone(socket, ~p"/", "There's no project called #{project.slug}.")

  defp missing(socket), do: deleted(socket)

  defp deleted(socket),
    do: gone(socket, ~p"/projects/#{socket.assigns.project.slug}", "That schedule was deleted.")

  # The owner's fields over `schedule`'s version, so the next save writes over it.
  defp keep_text(socket, schedule) do
    params = Map.put(socket.assigns.form.params, "version", Integer.to_string(schedule.version))
    initial = schedule |> Schedules.edit_params() |> normal()

    assign(socket,
      schedule: schedule,
      form: schedule_form(params),
      initial: initial,
      dirty?: normal(params) != initial,
      stale?: false
    )
  end

  ## What changed elsewhere

  @impl true
  def handle_info(_message, %{assigns: %{leaving?: true}} = socket), do: {:noreply, socket}

  def handle_info(
        {:schedules_changed, id},
        %{assigns: %{project: %{id: id}, schedule: %Schedule{}}} = socket
      ),
      do: {:noreply, refresh(socket)}

  def handle_info({:projects_changed, id}, %{assigns: %{project: %{id: id}}} = socket) do
    case Projects.get(id) do
      %Project{} = project ->
        socket = socket |> assign(project: project) |> load_threads()

        {:noreply,
         if(socket.assigns.item, do: with_item(socket, socket.assigns.item), else: socket)}

      nil ->
        {:noreply,
         gone(socket, ~p"/", "There's no project called #{socket.assigns.project.slug}.")}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # Re-reads the schedule for its next and last run, leaving the form as
  # it is; a version other than the form's means it was edited elsewhere.
  defp refresh(socket) do
    case Schedules.get(socket.assigns.schedule.id) do
      nil ->
        deleted(socket)

      item ->
        moved? = item.schedule.version != socket.assigns.schedule.version
        socket |> with_item(item) |> assign(stale?: socket.assigns.stale? or moved?)
    end
  end

  ## Rendering

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
            <:actions :if={@schedule}>
              <.button
                id="schedule-delete"
                size="sm"
                variant="danger"
                phx-click="delete"
                data-confirm="Delete this schedule? Threads it started stay."
              >
                <.icon name="hero-trash-micro" class="size-4" /> Delete
              </.button>
            </:actions>
          </.header>
          <p :if={!@schedule} class="mt-3 text-[14px] leading-relaxed text-ink-soft">
            A schedule starts a thread in {@project.name}, or wakes one, at set times.
          </p>

          <.status :if={@item} item={@item} titles={@titles} project={@project} />

          <.banner :if={@stale?} id="schedule-stale" tone="warn" icon="hero-arrow-path">
            This schedule changed since you opened it.
            <:actions>
              <.button id="schedule-reload" size="sm" phx-click="reload">
                Load the saved version
              </.button>
              <.button id="schedule-keep" size="sm" variant="ghost" phx-click="keep">
                Keep my text
              </.button>
            </:actions>
          </.banner>

          <.guarded_form
            for={@form}
            id="schedule-form"
            dirty={@dirty?}
            leave="Leave without saving? Your changes to this schedule will be lost."
            phx-change="validate"
            phx-submit="save"
            class="mt-6 rounded-2xl border border-line bg-surface shadow-xs"
          >
            <.input :if={@schedule} field={@form[:version]} type="hidden" id="schedule-version" />

            <div id={"schedule-fields-#{@revision}"} class="space-y-6 p-5">
              <div id="schedule-prompt-field">
                <.input
                  field={@form[:prompt]}
                  id="schedule-prompt"
                  type="textarea"
                  rows="4"
                  label="Prompt"
                  placeholder="Check last night's backups and note anything that failed."
                  hint="What should the thread be asked each time? It arrives as a message starting with [Scheduled]."
                  phx-debounce="300"
                  phx-mounted={is_nil(@schedule) && JS.focus()}
                />
              </div>

              <div id="schedule-at-field">
                <.local_datetime_input
                  id="schedule-at"
                  field={@form[:at]}
                  label="When"
                  hint="The first time it runs."
                />
              </div>

              <.repeat form={@form} />

              <div id="schedule-target-field">
                <.input
                  field={@form[:target]}
                  id="schedule-target"
                  type="select"
                  label="Thread"
                  options={target_options(@threads)}
                  hint="Each run starts a new thread, or sends the prompt to the thread you pick."
                />
              </div>
            </div>

            <div class="flex items-center justify-between gap-3 rounded-b-2xl border-t border-line bg-sunken/40 px-5 py-3">
              <p class="text-[12.5px] leading-relaxed text-ink-faint">
                <span
                  :if={@dirty?}
                  id="schedule-dirty"
                  class="inline-flex items-center gap-1.5 text-ink-soft"
                >
                  <.dot status={:warn} class="size-1.5" /> Unsaved changes.
                </span>
                <span :if={@schedule} id="schedule-restart-note">
                  Saving starts the schedule over from the next time after now.
                </span>
                <span :if={!@schedule and !@dirty?}>
                  It shows on {@project.name}'s page, where you can run it, edit it or delete it.
                </span>
              </p>
              <.button
                type="submit"
                variant="primary"
                size="sm"
                id="schedule-save"
                phx-disable-with="Saving..."
              >
                Save
              </.button>
            </div>
          </.guarded_form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :item, :map, required: true, doc: "the schedule, from `Photon.Schedules.get/1`"
  attr :titles, :map, required: true
  attr :project, Project, required: true

  # When the schedule runs next and what its last run did, with Run now.
  defp status(%{item: %{schedule: schedule}} = assigns) do
    assigns =
      assign(assigns,
        never?: schedule.last_run_at == nil,
        last?: schedule.last_run_at != nil and schedule.last_outcome != "failed"
      )

    ~H"""
    <section
      id="schedule-status"
      class="mt-6 flex flex-wrap items-center gap-x-4 gap-y-3 rounded-2xl border border-line bg-surface px-5 py-4 shadow-xs"
    >
      <div class="min-w-0 flex-1 space-y-1.5">
        <div id="schedule-next" class="flex items-start gap-2.5">
          <.icon name="hero-clock" class="mt-px size-4 shrink-0 text-ink-faint" />
          <.schedule_when id="schedule-status" item={@item} />
        </div>
        <div :if={@never? or @last?} id="schedule-last" class="flex items-start gap-2.5">
          <.icon name="hero-arrow-uturn-left" class="mt-px size-4 shrink-0 text-ink-faint" />
          <p :if={@never?} class="mt-0.5 text-[12px] text-ink-faint">Hasn't run yet.</p>
          <.last_run
            id="schedule-status"
            schedule={@item.schedule}
            thread_title={@titles[@item.schedule.last_thread_id]}
            thread_path={
              @item.schedule.last_thread_id &&
                ~p"/projects/#{@project.slug}/threads/#{@item.schedule.last_thread_id}"
            }
            class="mt-0.5 min-w-0"
          />
        </div>
      </div>
      <.button id="schedule-run" size="sm" phx-click="run" class="phx-click-loading:opacity-60">
        <.icon name="hero-play-micro" class="size-4" /> Run now
      </.button>
    </section>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true

  # Once or Every, and with Every the interval. The interval's fields stay
  # in the form while hidden, so switching back keeps them.
  defp repeat(%{form: form} = assigns) do
    assigns =
      assign(assigns,
        every?: form[:repeat].value == "every",
        errors: field_errors(form, :repeat) ++ field_errors(form, :every),
        units: unit_options(form[:every].value)
      )

    ~H"""
    <div id="schedule-repeat-field" class="space-y-1.5">
      <span class="block text-[13px] font-medium text-ink-soft">Repeat</span>
      <div class="flex flex-wrap items-center gap-2">
        <div
          id="schedule-repeat"
          role="radiogroup"
          aria-label="Repeat"
          class="inline-flex h-9 items-center rounded-full border border-line bg-sunken p-0.5"
        >
          <label :for={{value, label} <- [{"once", "Once"}, {"every", "Every"}]} class="relative">
            <input
              type="radio"
              id={"schedule-repeat-#{value}"}
              name={@form[:repeat].name}
              value={value}
              checked={@form[:repeat].value == value}
              class="peer sr-only"
            />
            <span class="block cursor-pointer rounded-full px-4 py-1 text-[13px] text-ink-faint transition select-none peer-checked:bg-surface peer-checked:font-medium peer-checked:text-ink peer-checked:shadow-xs peer-focus-visible:outline-2 peer-focus-visible:outline-accent hover:text-ink">
              {label}
            </span>
          </label>
        </div>
        <div class={["flex items-center gap-2", !@every? && "hidden"]}>
          <.input
            type="number"
            id="schedule-every"
            name={@form[:every].name}
            value={@form[:every].value}
            min="1"
            step="1"
            aria-label="How many"
            class={[field_class(), "w-20 tabular-nums", @errors != [] && "border-bad/60"]}
          />
          <.input
            type="select"
            id="schedule-unit"
            name={@form[:unit].name}
            value={@form[:unit].value}
            options={@units}
            aria-label="Unit"
            class={[field_class(), "w-auto pr-8"]}
          />
        </div>
      </div>
      <p :if={@every?} class="text-xs text-ink-faint">
        Repeats on a fixed interval from the first time.
      </p>
      <p :for={msg <- @errors} class="flex items-center gap-1.5 text-xs text-bad">
        <.icon name="hero-exclamation-circle-micro" class="size-4" />
        {msg}
      </p>
    </div>
    """
  end

  # A field's errors once the owner has used it, as `input/1` shows them.
  defp field_errors(form, field) do
    field = form[field]

    if Phoenix.Component.used_input?(field),
      do: Enum.map(field.errors, &translate_error/1),
      else: []
  end

  # The units, said in the singular for an interval of one.
  defp unit_options(every) do
    one? = String.trim(to_string(every)) == "1"
    for {plural, singular} <- @units, do: {if(one?, do: singular, else: plural), plural}
  end

  defp target_options(threads) do
    [
      {"A new thread each time", "new_thread"}
      | for(thread <- threads, do: {thread.title || "Untitled thread", thread.id})
    ]
  end
end
