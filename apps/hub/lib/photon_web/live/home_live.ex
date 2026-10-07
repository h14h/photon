defmodule PhotonWeb.HomeLive do
  @moduledoc """
  The home page at `/` (section 10.3 of
  `docs/plans/step-4-blip-as-coordinator.md`). For now it lists Blip's
  schedules; what needs the owner across every project arrives with the
  rest of that section. Blip floats over it, as over every page.

  Blip's schedules that are waiting for their next time, and those that
  stopped after an error (`Photon.Assistant.schedules/0`), which stay in
  sight with why and their cancel button showing until the owner cancels
  them, are a stream (`#schedule-list`), read here and again on
  `{:schedules_changed, nil}` (`Photon.Schedules.subscribe/0`). A
  project's schedules are on its page, and their announcements carry the
  project's ID, so they don't reload this list. Times are shown in the
  owner's time zone, in the lines a schedule shows wherever it is listed
  (`PhotonWeb.ScheduleComponents`). Everything else the shell passes on is
  ignored.
  """

  use PhotonWeb, :live_view

  import PhotonWeb.ScheduleComponents

  alias Photon.{Assistant, Schedules}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :ok = Schedules.subscribe()

    {:ok,
     socket
     |> assign(page_title: "Home")
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

  defp stopped?(%{state: state}), do: match?({:stopped, _reason}, state)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} shell={@shell} socket={@socket} active={:home}>
      <div class="h-full overflow-y-auto">
        <div class="blip-clear-y mx-auto w-full max-w-4xl px-4 py-8 sm:px-6">
          <.header>
            <span id="home-heading">Home</span>
          </.header>

          <section id="schedules" class="mt-8">
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
                <.icon
                  name={if(stopped?(item), do: "hero-exclamation-triangle", else: "hero-clock")}
                  class={[
                    "mt-0.5 size-4 shrink-0",
                    if(stopped?(item), do: "text-bad", else: "text-ink-faint")
                  ]}
                />
                <div class="min-w-0 flex-1">
                  <p class="leading-snug text-ink">{item.schedule.prompt}</p>
                  <.schedule_when id={dom_id} item={item} whose={:blip} />
                  <.last_run id={dom_id} schedule={item.schedule} class="mt-0.5" />
                </div>
                <button
                  id={"#{dom_id}-cancel"}
                  phx-click="cancel_schedule"
                  phx-value-id={item.id}
                  data-confirm="Cancel this schedule?"
                  class={[
                    "rounded-md p-1 text-ink-faint transition group-hover:opacity-100 hover:bg-bad-soft hover:text-bad",
                    !stopped?(item) && "sm:opacity-0"
                  ]}
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

  slot :inner_block, required: true

  defp section_title(assigns) do
    ~H"""
    <h2 class="text-[11px] font-semibold tracking-wider text-ink-faint uppercase">
      {render_slot(@inner_block)}
    </h2>
    """
  end
end
