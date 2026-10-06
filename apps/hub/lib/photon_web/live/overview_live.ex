defmodule PhotonWeb.OverviewLive do
  @moduledoc """
  The home page, at a glance: your machines and whether they're online, a
  pointer to Blip and to projects for work on them, and Blip's schedules.
  Blip floats over it, as over every page.

  Machines come from `@shell`, which keeps them current. Blip's schedules
  that are waiting for their next time (`Photon.Assistant.schedules/0`)
  are a stream (`#schedule-list`), read here and again on
  `{:schedules_changed, nil}` (`Photon.Schedules.subscribe/0`). A
  project's schedules are on its page, and their announcements carry the
  project's ID, so they don't reload this list. Times are shown in the
  owner's time zone (`PhotonWeb.TimeComponents.local_time/1`), with the
  words from `PhotonWeb.ScheduleText`.
  """

  use PhotonWeb, :live_view

  alias Photon.{Assistant, Schedules}
  alias PhotonWeb.ScheduleText

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :ok = Schedules.subscribe()

    {:ok,
     socket
     |> assign(page_title: "Overview")
     |> stream_configure(:schedules, dom_id: &"schedule-#{&1.id}")
     |> load_schedules()}
  end

  @impl true
  def handle_event("cancel_schedule", %{"id" => id}, socket) do
    case Assistant.cancel_schedule(id) do
      :ok -> {:noreply, socket}
      {:error, :not_found} -> {:noreply, load_schedules(socket)}
    end
  end

  @impl true
  def handle_info({:schedules_changed, nil}, socket), do: {:noreply, load_schedules(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_schedules(socket), do: stream(socket, :schedules, Assistant.schedules(), reset: true)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, online: Enum.count(assigns.shell.nodes, & &1.online))

    ~H"""
    <Layouts.app flash={@flash} shell={@shell} socket={@socket} active={:home}>
      <div class="h-full overflow-y-auto">
        <div class="blip-clear-y mx-auto w-full max-w-4xl px-4 py-8 sm:px-6">
          <.header>
            Overview
            <:subtitle>
              <span id="overview-summary">
                {summary(@online, length(@shell.nodes))}
              </span>
            </:subtitle>
          </.header>

          <section id="machines" class="mt-8">
            <.section_title>Machines</.section_title>
            <div
              :if={@shell.nodes == []}
              id="no-machines"
              class="mt-3 rounded-2xl border border-dashed border-line-strong px-5 py-6 text-[14px] text-ink-soft"
            >
              No machines yet. Add one from the <.link
                navigate={~p"/nodes"}
                class="text-accent-strong underline underline-offset-2"
              >
                Nodes page</.link>.
            </div>
            <div class="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
              <.machine :for={node <- @shell.nodes} node={node} />
            </div>
            <p
              :if={@shell.nodes != []}
              id="work-hint"
              class="mt-4 flex items-center gap-2 text-[14px] text-ink-soft"
            >
              <.icon name="hero-chat-bubble-left-ellipsis" class="size-4 shrink-0 text-ink-faint" />
              <span>
                Ask Blip to run something on any of these, or
                <.link
                  id="work-hint-new-project"
                  navigate={~p"/projects/new"}
                  class="text-accent-strong underline underline-offset-2"
                >start a project</.link>
                for longer work.
              </span>
            </p>
          </section>

          <section id="schedules" class="mt-9">
            <.section_title>Schedules</.section_title>
            <div id="schedule-list" phx-update="stream" class="mt-3 space-y-2">
              <p
                id="no-schedules"
                class="hidden text-[14px] leading-relaxed text-ink-faint only:block"
              >
                None yet. Ask Blip for something recurring, like "every morning, check my disks".
                Project schedules are on each project's page.
              </p>
              <div
                :for={{dom_id, item} <- @streams.schedules}
                id={dom_id}
                class="group flex items-start gap-3 rounded-xl border border-line bg-surface px-4 py-3 text-[14px] shadow-xs"
              >
                <.icon name="hero-clock" class="mt-0.5 size-4 shrink-0 text-ink-faint" />
                <div class="min-w-0 flex-1">
                  <p class="leading-snug text-ink">{item.schedule.prompt}</p>
                  <.schedule_when id={dom_id} item={item} />
                  <p
                    :if={item.schedule.last_run_at}
                    id={"#{dom_id}-last"}
                    class="mt-0.5 text-[12px] text-ink-faint"
                  >
                    Last ran
                    <.local_time
                      id={"#{dom_id}-last-at"}
                      at={item.schedule.last_run_at}
                    />: {ScheduleText.outcome(item.schedule.last_outcome)}
                  </p>
                </div>
                <button
                  phx-click="cancel_schedule"
                  phx-value-id={item.id}
                  data-confirm="Cancel this schedule?"
                  class="rounded-md p-1 text-ink-faint transition group-hover:opacity-100 hover:bg-bad-soft hover:text-bad sm:opacity-0"
                  title="Cancel"
                >
                  <.icon name="hero-x-mark-micro" class="size-4" />
                </button>
              </div>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp summary(_online, 0), do: "Add a machine and Blip can start working on it."
  defp summary(online, total), do: "#{online} of #{total} #{plural(total, "machine")} online."

  defp plural(1, word), do: word
  defp plural(_n, word), do: word <> "s"

  slot :inner_block, required: true

  defp section_title(assigns) do
    ~H"""
    <h2 class="text-[11px] font-semibold tracking-wider text-ink-faint uppercase">
      {render_slot(@inner_block)}
    </h2>
    """
  end

  attr :node, :map, required: true

  defp machine(assigns) do
    ~H"""
    <div
      id={"machine-#{@node.id}"}
      class="rounded-2xl border border-line bg-surface px-4 py-3.5 shadow-xs transition"
    >
      <div class="flex items-center gap-2">
        <.dot status={if(@node.online, do: :ok, else: :off)} />
        <span class={["truncate font-medium", !@node.online && "text-ink-faint"]}>{@node.id}</span>
        <span class="ml-auto shrink-0 text-[12px] text-ink-faint">
          {if(@node.online, do: "online", else: "offline")}
        </span>
      </div>
      <p class="mt-2 truncate text-[13px] text-ink-faint">{machine_line(@node)}</p>
    </div>
    """
  end

  # What the card says under a machine's name: its host and platform while
  # it's connected.
  defp machine_line(%{online: true, info: info}),
    do:
      [info["hostname"], info["platform"]] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · ")

  defp machine_line(_node), do: "Not connected"

  attr :id, :string, required: true
  attr :item, :map, required: true, doc: "a schedule from `Photon.Assistant.schedules/0`"

  # When a schedule runs next: "Every day · next <local time>" or "Once ·
  # <local time>" (`PhotonWeb.ScheduleText.state/2`). The list holds only
  # waiting schedules, but the other states read right here too.
  defp schedule_when(%{item: item} = assigns) do
    {tone, words} = ScheduleText.state(item.state, item.schedule.every_minutes)
    assigns = assign(assigns, tone: tone, words: words)

    ~H"""
    <p
      id={"#{@id}-when"}
      class={["mt-0.5 text-[12px]", if(@tone == :stopped, do: "text-bad", else: "text-ink-faint")]}
    >
      {@words}
      <.local_time :if={@tone == :next && @item.next_at} id={"#{@id}-next"} at={@item.next_at} />
    </p>
    """
  end
end
