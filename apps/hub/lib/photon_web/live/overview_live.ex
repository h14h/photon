defmodule PhotonWeb.OverviewLive do
  @moduledoc """
  The home page: everything the hub is running, at a glance. Your machines
  and whether they're online, node work going now, work that finished
  lately, and what's scheduled. Blip floats over it, as over every page.

  Machines and sessions come from `@shell`, which keeps them current;
  schedules are read here and again on `{:durable_tasks, _}`.
  """

  use PhotonWeb, :live_view

  alias Photon.Assistant

  # How many finished sessions "Recent work" shows.
  @recent 8

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Overview", schedules: Assistant.schedules())}
  end

  @impl true
  def handle_event("cancel_schedule", %{"id" => id}, socket) do
    Assistant.cancel_schedule(id)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:durable_tasks, tasks}, socket) do
    if Enum.any?(tasks, &(&1.kind == "routine")),
      do: {:noreply, assign(socket, schedules: Assistant.schedules())},
      else: {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    {running, finished} =
      Enum.split_with(assigns.shell.sessions, &(&1.status in ["running", "pending"]))

    assigns =
      assign(assigns,
        running: running,
        recent: Enum.take(finished, @recent),
        online: Enum.count(assigns.shell.nodes, & &1.online),
        now: DateTime.utc_now()
      )

    ~H"""
    <Layouts.app flash={@flash} shell={@shell} socket={@socket} active={:overview}>
      <div class="h-full overflow-y-auto">
        <div class="blip-clear-y mx-auto w-full max-w-4xl px-4 py-8 sm:px-6">
          <.header>
            Overview
            <:subtitle>
              <span id="overview-summary">
                {summary(@online, length(@shell.nodes), length(@running))}
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
              No machines yet, so Blip has nowhere to send work.
              <.link navigate={~p"/nodes"} class="text-accent-strong underline underline-offset-2">
                Add one
              </.link>
            </div>
            <div class="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
              <.machine
                :for={node <- @shell.nodes}
                node={node}
                sessions={Enum.filter(@shell.sessions, &(&1.node_id == node.id))}
              />
            </div>
          </section>

          <section id="running" class="mt-9">
            <.section_title>Running now</.section_title>
            <p :if={@running == []} class="mt-3 text-[14px] text-ink-faint">
              Nothing running on your machines.
            </p>
            <div :if={@running != []} class="mt-3 space-y-2">
              <.work :for={s <- @running} session={s} now={@now} />
            </div>
          </section>

          <section id="recent" class="mt-9">
            <.section_title>Recent work</.section_title>
            <p :if={@recent == []} class="mt-3 text-[14px] text-ink-faint">
              Nothing has finished yet.
            </p>
            <div :if={@recent != []} class="mt-3 space-y-2">
              <.work :for={s <- @recent} session={s} now={@now} />
            </div>
          </section>

          <section id="schedules" class="mt-9">
            <.section_title>Schedules</.section_title>
            <p :if={@schedules == []} class="mt-3 text-[14px] leading-relaxed text-ink-faint">
              None yet. Ask Blip for something recurring, like "every morning, check my disks".
            </p>
            <div :if={@schedules != []} class="mt-3 space-y-2">
              <div
                :for={task <- @schedules}
                id={"schedule-#{task.id}"}
                class="group flex items-start gap-3 rounded-xl border border-line bg-surface px-4 py-3 text-[14px] shadow-xs"
              >
                <.icon name="hero-clock" class="mt-0.5 size-4 shrink-0 text-ink-faint" />
                <div class="min-w-0 flex-1">
                  <p class="leading-snug text-ink">{task.input["prompt"]}</p>
                  <p class="mt-0.5 text-[12px] text-ink-faint">{schedule_text(task)}</p>
                </div>
                <button
                  phx-click="cancel_schedule"
                  phx-value-id={task.id}
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

  defp summary(_online, 0, _running), do: "Add a machine and Blip can start working on it."

  defp summary(online, total, running) do
    machines = "#{online} of #{total} #{plural(total, "machine")} online"

    case running do
      0 -> machines <> ". Nothing running."
      n -> machines <> ". #{n} #{plural(n, "thing")} running."
    end
  end

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
  attr :sessions, :list, required: true

  defp machine(assigns) do
    assigns =
      assign(assigns,
        running: Enum.count(assigns.sessions, &(&1.status == "running")),
        latest: List.first(assigns.sessions)
      )

    ~H"""
    <div
      id={"machine-#{@node.id}"}
      class={[
        "rounded-2xl border bg-surface px-4 py-3.5 shadow-xs transition",
        @running > 0 && "border-accent/40",
        @running == 0 && "border-line"
      ]}
    >
      <div class="flex items-center gap-2">
        <.dot status={
          cond do
            !@node.online -> :off
            @running > 0 -> :busy
            true -> :ok
          end
        } />
        <span class={["truncate font-medium", !@node.online && "text-ink-faint"]}>{@node.id}</span>
        <span class="ml-auto shrink-0 text-[12px] text-ink-faint">
          {cond do
            !@node.online -> "offline"
            @running > 0 -> "#{@running} running"
            true -> "online"
          end}
        </span>
      </div>
      <.link
        :if={@latest}
        navigate={~p"/sessions/#{@latest.id}"}
        class="mt-2 block truncate text-[13px] text-ink-soft hover:text-ink"
      >
        {@latest.title}
      </.link>
      <p :if={!@latest} class="mt-2 text-[13px] text-ink-faint">No work yet.</p>
    </div>
    """
  end

  attr :session, :map, required: true
  attr :now, DateTime, required: true

  defp work(assigns) do
    assigns = assign(assigns, state: state(assigns.session))

    ~H"""
    <.link
      navigate={~p"/sessions/#{@session.id}"}
      id={"work-#{@session.id}"}
      class="flex items-center gap-3 rounded-xl border border-line bg-surface px-4 py-2.5 text-[14px] shadow-xs transition hover:border-accent/40"
    >
      <span class="grid size-5 shrink-0 place-items-center">
        <Layouts.session_badge status={@state} />
        <.icon
          :if={@state == "done"}
          name="hero-check-circle-micro"
          class="size-4 text-ok"
        />
      </span>
      <span class="min-w-0 flex-1">
        <span class="block truncate text-ink">{@session.title}</span>
        <span class="text-[12px] text-ink-faint">
          {@session.node_id} · {if(@session.origin == "assistant", do: "by Blip", else: "by you")}
        </span>
      </span>
      <span class="shrink-0 text-[12px] text-ink-faint tabular-nums">{ago(@session.updated_at, @now)}</span>
    </.link>
    """
  end

  # A session's status as the list shows it: an idle session ended its last
  # turn, well or not.
  defp state(%{status: "idle", last_failure: failure}) when failure not in [nil, ""], do: "failed"
  defp state(%{status: "idle"}), do: "done"
  defp state(%{status: status}), do: status

  defp ago(at, now) do
    seconds = max(DateTime.diff(now, at), 0)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp schedule_text(task) do
    next = task.checkpoint["next_at"] || task.input["first_at"]
    next = next |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%b %-d, %H:%M UTC")

    case task.input["every_ms"] do
      nil -> "Once, #{next}"
      every -> "Every #{format_interval(every)} · next #{next}"
    end
  end

  defp format_interval(ms) do
    minutes = div(ms, 60_000)

    cond do
      rem(minutes, 1440) == 0 -> "#{div(minutes, 1440)}d"
      rem(minutes, 60) == 0 -> "#{div(minutes, 60)}h"
      true -> "#{minutes}m"
    end
  end
end
