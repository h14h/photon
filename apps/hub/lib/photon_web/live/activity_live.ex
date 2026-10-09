defmodule PhotonWeb.ActivityLive do
  @moduledoc """
  The activity page at `/activity`: everything Blip did, and who asked,
  newest first, from `Photon.Activity`'s log.

  The rows are a stream (`#activity-list`), 50 at a time; `Show older`
  appends the next 50 past the last row shown, kept as `cursor`. The
  filter form (`#activity-filter`) narrows them to one kind of asker
  and to the calls that change something, and resets the stream. A row
  recorded while the page is open arrives as `{:activity_added, id}`
  (`Photon.Activity.subscribe/0`) and goes on top when it passes the
  filter. Since streams can't be counted, `empty?` says whether any row
  is shown, for `#no-activity`.

  Each page of rows is shown with the titles, prompts and projects it
  names, read with it (`Photon.Threads.places/1`,
  `Photon.Schedules.prompts/1`, `Photon.Projects.list/0`); the words and
  what links where are `PhotonWeb.ActivityText`'s. Times are shown in
  the owner's time zone (`PhotonWeb.TimeComponents.local_time/1`).

  The threads the rows on screen name are kept with the titles they
  were shown under (`named`). On `{:projects_changed, _}` (through
  `PhotonWeb.Shell`: a thread named after its first run, or renamed),
  the page reads those titles again, one read by ID however often
  projects change (rule 73), and only when one changed reads the rows
  on screen again (`shown` of them), so they say the new title.
  Everything else the shell passes on is ignored.
  """

  use PhotonWeb, :live_view

  alias Photon.{Activity, Projects, Schedules, Threads}
  alias Photon.Activity.Action
  alias PhotonWeb.{ActivityText, ConversationComponents}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :ok = Activity.subscribe()

    {:ok,
     socket
     |> assign(page_title: "Activity")
     |> stream_configure(:actions, dom_id: &"activity-#{&1.id}")
     |> load(ActivityText.all())}
  end

  ## Events

  @impl true
  def handle_event("filter", %{"filter" => params}, socket),
    do: {:noreply, load(socket, ActivityText.filter(params))}

  def handle_event("more", _params, socket) do
    opts = [before: socket.assigns.cursor] ++ ActivityText.list_opts(socket.assigns.filter)
    {actions, more?} = Activity.list(opts)
    {rows, named} = present(actions)

    {:noreply,
     socket
     |> stream(:actions, rows)
     |> assign(more?: more?, cursor: cursor(actions, socket.assigns.cursor))
     |> assign(named: Map.merge(socket.assigns.named, named))
     |> update(:shown, &(&1 + length(actions)))}
  end

  ## What changed elsewhere

  @impl true
  def handle_info({:activity_added, id}, socket) do
    case Activity.get(id) do
      %Action{} = action -> {:noreply, added(socket, action)}
      nil -> {:noreply, socket}
    end
  end

  # A thread may have a new title: the rows naming one say it.
  def handle_info({:projects_changed, _project_id}, socket), do: {:noreply, retitle(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Reading

  # The newest page of rows for `filter`, in place of what was shown.
  defp load(socket, filter), do: load(socket, filter, [])

  # The newest rows for `filter` (`opts` may ask for more than a page),
  # in place of what was shown.
  defp load(socket, filter, opts) do
    {actions, more?} = Activity.list(opts ++ ActivityText.list_opts(filter))
    {rows, named} = present(actions)

    socket
    |> assign(filter: filter, form: to_form(ActivityText.params(filter), as: :filter))
    |> assign(more?: more?, empty?: actions == [], cursor: cursor(actions, nil))
    |> assign(named: named, shown: length(actions))
    |> stream(:actions, rows, reset: true)
  end

  # Reads the titles of the threads on screen, and the rows again when
  # one of them changed.
  defp retitle(%{assigns: %{named: named}} = socket) when map_size(named) > 0 do
    titles = named |> Map.keys() |> Threads.titles()

    if Enum.all?(named, fn {id, title} -> titles[id] == title end),
      do: socket,
      else: load(socket, socket.assigns.filter, limit: max(socket.assigns.shown, 1))
  end

  defp retitle(socket), do: socket

  # A row recorded while the page is open goes on top, if it passes the
  # filter. The cursor stays: Show older goes on past the oldest row.
  defp added(socket, action) do
    if ActivityText.matches?(action, socket.assigns.filter) do
      {[row], named} = present([action])

      socket
      |> stream_insert(:actions, row, at: 0)
      |> assign(empty?: false, named: Map.merge(socket.assigns.named, named))
      |> update(:shown, &(&1 + 1))
    else
      socket
    end
  end

  defp cursor([], cursor), do: cursor
  defp cursor(actions, _cursor), do: List.last(actions)

  # Rows as the page draws them, with what they name, and the titles of
  # the threads they name, by ID.
  defp present([]), do: {[], %{}}

  defp present(actions) do
    wanted = ActivityText.wanted(actions)

    lookup = %{
      places: Threads.places(wanted.threads),
      prompts: Schedules.prompts(wanted.schedules),
      projects: Map.new(Projects.list(), &{&1.id, %{name: &1.name, slug: &1.slug}})
    }

    {Enum.map(actions, &ActivityText.row(&1, lookup)),
     Map.new(lookup.places, fn {id, place} -> {id, place.title} end)}
  end

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} shell={@shell} socket={@socket} active={:activity}>
      <div class="h-full overflow-y-auto">
        <div class="blip-clear-y mx-auto w-full max-w-3xl px-4 py-8 sm:px-6">
          <.header>
            <span id="activity-heading">Activity</span>
            <:subtitle>Everything Blip did, and who asked.</:subtitle>
          </.header>

          <.form
            for={@form}
            id="activity-filter"
            phx-change="filter"
            class="mt-6 flex flex-wrap items-center gap-x-5 gap-y-3"
          >
            <div class="flex items-center gap-2.5">
              <label for="activity-origin" class="text-[13px] font-medium text-ink-soft">
                Who asked
              </label>
              <div class="w-44">
                <.input
                  field={@form[:origin]}
                  id="activity-origin"
                  type="select"
                  options={ActivityText.origin_options()}
                />
              </div>
            </div>
            <.input
              field={@form[:changes]}
              id="activity-changes"
              type="checkbox"
              label="Changes only"
            />
          </.form>

          <div
            :if={@empty?}
            id="no-activity"
            class="mt-6 rounded-2xl border border-dashed border-line-strong px-6 py-10 text-center"
          >
            <span class="mx-auto flex size-10 items-center justify-center rounded-full bg-accent-soft text-accent-strong">
              <.icon
                name={if(@filter == ActivityText.all(), do: "hero-queue-list", else: "hero-funnel")}
                class="size-5"
              />
            </span>
            <p class="mx-auto mt-3 max-w-sm text-[14px] leading-relaxed text-ink-soft">
              {ActivityText.empty(@filter)}
            </p>
          </div>

          <ol id="activity-list" phx-update="stream" class="mt-5 space-y-2">
            <.action_row :for={{dom_id, row} <- @streams.actions} id={dom_id} row={row} />
          </ol>

          <div :if={@more?} class="mt-5 flex justify-center">
            <.button id="activity-more" size="sm" phx-click="more">
              <.icon name="hero-chevron-down-micro" class="size-4" /> Show older
            </.button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :row, :map, required: true

  # One thing Blip did: its mark, what it did, who asked, where, and when.
  # The summary already ends ": failed" or ": stopped"; the mark's colour
  # and its title say so at a glance.
  defp action_row(assigns) do
    ~H"""
    <li
      id={@id}
      data-status={@row.status}
      class="flex items-start gap-3 rounded-xl border border-line bg-surface px-4 py-3 shadow-xs transition hover:border-line-strong"
    >
      <span
        id={"#{@id}-mark"}
        title={ActivityText.status_text(@row.status)}
        class={[
          "mt-px grid size-6 shrink-0 place-items-center rounded-md",
          @row.kind == "message" && "bg-accent-soft text-accent-strong",
          @row.kind != "message" && @row.status == :ok && "bg-ok-soft text-ok",
          @row.status == :failed && "bg-bad-soft text-bad",
          @row.status in [:stopped, :interrupted] && "bg-sunken text-ink-faint"
        ]}
      >
        <.icon name={mark_icon(@row)} class="size-3.5" />
      </span>
      <div class="min-w-0 flex-1">
        <div class="flex items-baseline gap-3">
          <p
            id={"#{@id}-summary"}
            class={[
              "min-w-0 flex-1 text-[14px] leading-snug break-words",
              @row.status == :ok && "text-ink",
              @row.status != :ok && "text-ink-soft"
            ]}
          >
            {@row.summary}
          </p>
          <span class="shrink-0 text-[12px] text-ink-faint">
            <.local_time id={"#{@id}-at"} at={@row.at} />
          </span>
        </div>
        <div class="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-[12.5px] text-ink-faint">
          <span id={"#{@id}-origin"} class="inline-flex min-w-0 items-center gap-1.5">
            <.icon name={origin_icon(@row.origin.by)} class="size-3.5 shrink-0" />
            <span class="min-w-0 truncate">
              {@row.origin.lead}<.link
                :if={@row.origin.thread}
                navigate={thread_path(@row.origin.thread)}
                id={"#{@id}-origin-thread"}
                class="font-medium text-ink-soft transition hover:text-accent-strong"
              >{@row.origin.thread.title}</.link>
            </span>
          </span>
          <span
            :if={@row.project}
            id={"#{@id}-target"}
            class="inline-flex min-w-0 items-center gap-1.5"
          >
            <.icon name="hero-folder-micro" class="size-3.5 shrink-0" />
            <.link
              navigate={~p"/projects/#{@row.project.slug}"}
              id={"#{@id}-project"}
              class="shrink-0 transition hover:text-ink"
            >
              {@row.project.name}
            </.link>
            <%= if @row.thread do %>
              <span class="text-ink-faint/60">/</span>
              <.link
                navigate={thread_path(@row.thread)}
                id={"#{@id}-thread"}
                class="min-w-0 truncate text-ink-soft transition hover:text-accent-strong"
              >
                {@row.thread.title}
              </.link>
            <% end %>
          </span>
        </div>
      </div>
    </li>
    """
  end

  defp mark_icon(%{kind: "message"}), do: "hero-chat-bubble-left-ellipsis-micro"
  defp mark_icon(%{status: :failed}), do: "hero-exclamation-triangle-micro"
  defp mark_icon(%{status: status}) when status in [:stopped, :interrupted], do: "hero-stop-micro"
  defp mark_icon(%{tool: tool}), do: ConversationComponents.action_icon(tool)

  defp origin_icon("owner"), do: "hero-user-micro"
  defp origin_icon("thread"), do: "hero-chat-bubble-left-right-micro"
  defp origin_icon("schedule"), do: "hero-clock-micro"
  defp origin_icon("follow_up"), do: "hero-arrow-uturn-right-micro"
  defp origin_icon(_unknown), do: "hero-sparkles-micro"

  defp thread_path(thread), do: ~p"/projects/#{thread.slug}/threads/#{thread.id}"
end
