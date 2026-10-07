defmodule PhotonWeb.HomeLive do
  @moduledoc """
  The home page at `/` (section 10.3 of
  `docs/plans/step-4-blip-as-coordinator.md`): what needs the owner
  across every project, what is running, what has gone quiet, and Blip's
  schedules. Blip floats over it, as over every page.

  The threads come from `Photon.Threads.board(:all)`, grouped by
  `Photon.Threads.State.sections/1`:

    * Needs you: Waiting on you (questions Blip or the hub passed to the
      owner, each with its own answer form, and threads whose last answer
      asked something), Failed, and Finished (unread, with Mark all read)
    * Running: threads at work, then threads waiting on Blip's answer
    * Gone quiet: stopped threads left alone for a few days

  Each section is a stream, reset on every read; the counts that decide
  which sections and empty states show, and the summary, are assigns,
  since streams can't be counted. The board is read again on
  `{:projects_changed, _}` and `{:questions_changed, _}` (the shell
  subscribes to both, and passes them on) and once a minute, so a thread
  passes into Gone quiet without an event.

  An answer form's text is kept in `drafts` as it is typed, by question
  ID, so a re-read draws the rows with what was typed; a draft and any
  refusal shown under its form go when the question is answered or
  closes. Answers go through `Photon.Questions.answer/2`, whose refusals
  are already in the owner's words. Resolve and Mark all read go through
  `Photon.Threads`.

  Blip's schedules that are waiting for their next time, and those that
  stopped after an error (`Photon.Assistant.schedules/0`), which stay in
  sight with why and their cancel button showing until the owner cancels
  them, are a stream (`#schedule-list`), read here and again on
  `{:schedules_changed, nil}` (`Photon.Schedules.subscribe/0`). A
  project's schedules are on its page, and their announcements carry the
  project's ID, so they don't reload this list. Times are shown in the
  owner's time zone (`PhotonWeb.TimeComponents.local_time/1`). Everything
  else the shell passes on is ignored.
  """

  use PhotonWeb, :live_view

  import PhotonWeb.ConversationComponents, only: [answer_box: 1]
  import PhotonWeb.ScheduleComponents

  alias Photon.{Assistant, Questions, Schedules, Threads}
  alias Photon.Threads.State
  alias PhotonWeb.ThreadText

  # The rows move between sections with time (Gone quiet), so the board
  # is read again once a minute.
  @tick_ms :timer.minutes(1)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Schedules.subscribe()
      tick()
    end

    {:ok,
     socket
     |> assign(page_title: "Home", drafts: %{}, errors: %{})
     |> stream_configure(:waiting, dom_id: &waiting_dom_id/1)
     |> stream_configure(:failed, dom_id: &"failed-#{&1.thread.id}")
     |> stream_configure(:unread, dom_id: &"unread-#{&1.thread.id}")
     |> stream_configure(:running, dom_id: &"running-#{&1.thread.id}")
     |> stream_configure(:quiet, dom_id: &"quiet-#{&1.thread.id}")
     |> stream_configure(:schedules, dom_id: &"schedule-#{&1.id}")
     |> load_board()
     |> load_schedules()}
  end

  defp waiting_dom_id(%{kind: :question, id: id}), do: "question-#{id}"
  defp waiting_dom_id(%{kind: :thread, id: id}), do: "waiting-#{id}"

  defp tick do
    # Never cancelled: it fires once and the next is set then; it dies with the page.
    _timer = Process.send_after(self(), :tick, @tick_ms)
    :ok
  end

  ## Events

  @impl true
  def handle_event("draft", %{"question_id" => id, "answer" => %{"text" => text}}, socket),
    do: {:noreply, update(socket, :drafts, &Map.put(&1, id, text))}

  def handle_event("answer", %{"question_id" => id, "answer" => %{"text" => text}}, socket) do
    case Questions.answer(id, text) do
      {:ok, _question} ->
        {:noreply, socket |> forget(id) |> load_board()}

      {:error, message} ->
        {:noreply,
         socket
         |> update(:drafts, &Map.put(&1, id, text))
         |> update(:errors, &Map.put(&1, id, message))
         |> load_board()}
    end
  end

  def handle_event("resolve", %{"id" => thread_id}, socket) do
    # A thread that is gone is simply no longer listed after the re-read.
    _resolved = Threads.resolve(thread_id)
    {:noreply, load_board(socket)}
  end

  def handle_event("mark_all_read", _params, socket) do
    count = Threads.mark_all_seen()
    {:noreply, socket |> put_flash(:info, ThreadText.marked_read(count)) |> load_board()}
  end

  def handle_event("cancel_schedule", %{"id" => id}, socket) do
    case Assistant.cancel_schedule(id) do
      :ok -> {:noreply, socket}
      {:error, :not_found} -> {:noreply, load_schedules(socket)}
    end
  end

  defp forget(socket, id) do
    socket
    |> update(:drafts, &Map.delete(&1, id))
    |> update(:errors, &Map.delete(&1, id))
  end

  ## What changed elsewhere

  @impl true
  def handle_info({:projects_changed, _project_id}, socket), do: {:noreply, load_board(socket)}
  def handle_info({:questions_changed, _thread_id}, socket), do: {:noreply, load_board(socket)}
  def handle_info({:schedules_changed, nil}, socket), do: {:noreply, load_schedules(socket)}

  def handle_info(:tick, socket) do
    tick()
    {:noreply, load_board(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Reading

  defp load_board(socket) do
    sections = State.sections(Threads.board(:all))
    open = for %{kind: :question, id: id} <- sections.waiting, do: id
    drafts = Map.take(socket.assigns.drafts, open)
    errors = Map.take(socket.assigns.errors, open)

    socket
    |> assign(drafts: drafts, errors: errors, needs_you: sections.needs_you)
    |> assign(counts: counts(sections), more: more_counts(sections))
    |> stream(:waiting, Enum.map(sections.waiting, &with_form(&1, drafts, errors)), reset: true)
    |> stream(:failed, sections.failed.rows, reset: true)
    |> stream(:unread, sections.unread.rows, reset: true)
    |> stream(:running, sections.running, reset: true)
    |> stream(:quiet, sections.quiet.rows, reset: true)
  end

  defp counts(sections) do
    %{
      waiting: length(sections.waiting),
      failed: length(sections.failed.rows) + sections.failed.more,
      unread: length(sections.unread.rows) + sections.unread.more,
      running: length(sections.running),
      quiet: length(sections.quiet.rows) + sections.quiet.more
    }
  end

  defp more_counts(sections),
    do: %{failed: sections.failed.more, unread: sections.unread.more, quiet: sections.quiet.more}

  # A question's row carries its answer form, with what was typed so far,
  # and the refusal of the last try, if any.
  defp with_form(%{kind: :question, id: id} = row, drafts, errors) do
    Map.merge(row, %{
      form: to_form(%{"text" => Map.get(drafts, id, "")}, as: :answer),
      error: Map.get(errors, id)
    })
  end

  defp with_form(row, _drafts, _errors), do: row

  defp load_schedules(socket), do: stream(socket, :schedules, Assistant.schedules(), reset: true)

  defp stopped?(%{state: state}), do: match?({:stopped, _reason}, state)

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} shell={@shell} socket={@socket} active={:home}>
      <div class="h-full overflow-y-auto">
        <div class="blip-clear-y mx-auto w-full max-w-4xl px-4 py-8 sm:px-6">
          <.header>
            <span id="home-heading">Home</span>
            <:subtitle>
              <span id="home-summary">{ThreadText.summary(@needs_you)}</span>
            </:subtitle>
          </.header>

          <section
            :if={@shell.projects == []}
            id="home-start"
            class="mt-8 rounded-2xl border border-dashed border-line-strong px-5 py-6"
          >
            <p class="text-[14.5px] leading-relaxed text-ink-soft">
              Start a project for work that takes more than one message, or ask Blip for anything.
            </p>
            <p
              :if={@shell.nodes == []}
              class="mt-2 text-[14px] leading-relaxed text-ink-faint"
            >
              Add a machine from the
              <.link
                navigate={~p"/nodes"}
                id="home-add-machine"
                class="text-accent-strong underline underline-offset-2"
              >Nodes page</.link>
              so Blip and threads can run commands.
            </p>
            <.button
              navigate={~p"/projects/new"}
              id="home-new-project"
              variant="primary"
              size="sm"
              class="mt-4"
            >
              <.icon name="hero-plus-micro" class="size-4" /> Start a project
            </.button>
          </section>

          <section :if={@shell.projects != []} id="needs-you" class="mt-8">
            <.section_title>Needs you</.section_title>
            <p
              :if={@counts.waiting + @counts.failed + @counts.unread == 0}
              id="nothing-needs-you"
              class="mt-3 flex items-center gap-2.5 rounded-2xl border border-dashed border-line-strong px-5 py-5 text-[14px] leading-relaxed text-ink-soft"
            >
              <.icon name="hero-check-circle" class="size-5 shrink-0 text-ok" />
              Nothing needs you. Blip will say when something does.
            </p>

            <div :if={@counts.waiting > 0} id="waiting" class="mt-4">
              <.subhead title="Waiting on you" count={@counts.waiting} state={:waiting} />
              <div id="waiting-list" phx-update="stream" class="mt-2 space-y-2">
                <%= for {dom_id, row} <- @streams.waiting do %>
                  <.question_row :if={row.kind == :question} id={dom_id} row={row} />
                  <.asked_row :if={row.kind == :thread} id={dom_id} entry={row.entry} />
                <% end %>
              </div>
            </div>

            <div :if={@counts.failed > 0} id="failed" class="mt-6">
              <.subhead title="Failed" count={@counts.failed} state={:failed} />
              <div id="failed-list" phx-update="stream" class="mt-2 space-y-2">
                <.thread_row :for={{dom_id, entry} <- @streams.failed} id={dom_id} entry={entry}>
                  <:detail>
                    <span class="text-bad/90">{entry.thread.last_run_note || "Failed"}</span>
                  </:detail>
                  <:at :if={entry.thread.last_run_ended_at}>
                    <.local_time id={"#{dom_id}-at"} at={entry.thread.last_run_ended_at} />
                  </:at>
                  <:actions>
                    <.resolve id={"#{dom_id}-resolve"} thread_id={entry.thread.id} />
                  </:actions>
                </.thread_row>
              </div>
              <.more :if={@more.failed > 0} id="failed-more" count={@more.failed} />
            </div>

            <div :if={@counts.unread > 0} id="unread" class="mt-6">
              <.subhead title="Finished" count={@counts.unread} state={:unread}>
                <.button
                  id="mark-all-read"
                  size="sm"
                  variant="ghost"
                  phx-click="mark_all_read"
                >
                  <.icon name="hero-check-micro" class="size-4" /> Mark all read
                </.button>
              </.subhead>
              <div id="unread-list" phx-update="stream" class="mt-2 space-y-2">
                <.thread_row :for={{dom_id, entry} <- @streams.unread} id={dom_id} entry={entry}>
                  <:detail :if={entry.thread.last_run_note}>{entry.thread.last_run_note}</:detail>
                  <:at :if={entry.thread.last_run_ended_at}>
                    <.local_time id={"#{dom_id}-at"} at={entry.thread.last_run_ended_at} />
                  </:at>
                </.thread_row>
              </div>
              <.more :if={@more.unread > 0} id="unread-more" count={@more.unread} />
            </div>
          </section>

          <section :if={@shell.projects != []} id="running" class="mt-9">
            <.section_title>Running</.section_title>
            <div id="running-list" phx-update="stream" class="mt-3 space-y-2">
              <p id="no-running" class="hidden text-[14px] leading-relaxed text-ink-faint only:block">
                Nothing running.
              </p>
              <.thread_row
                :for={{dom_id, entry} <- @streams.running}
                id={dom_id}
                entry={entry}
                data-state={entry.state}
              >
                <:detail :if={entry.state == :asking}>
                  <span class="text-ink-soft">Waiting on Blip:</span>
                  {asked(entry)}
                </:detail>
                <:detail :if={entry.state != :asking}>
                  Running since <.local_time id={"#{dom_id}-at"} at={entry.thread.active_at} />
                </:detail>
              </.thread_row>
            </div>
          </section>

          <section :if={@shell.projects != [] and @counts.quiet > 0} id="quiet" class="mt-9">
            <.section_title>Gone quiet</.section_title>
            <div id="quiet-list" phx-update="stream" class="mt-3 space-y-2">
              <.thread_row :for={{dom_id, entry} <- @streams.quiet} id={dom_id} entry={entry}>
                <:detail>{ThreadText.quiet(entry.thread)}</:detail>
                <:at :if={State.last_activity(entry.thread)}>
                  last active
                  <.local_time id={"#{dom_id}-at"} at={State.last_activity(entry.thread)} />
                </:at>
                <:actions>
                  <.resolve id={"#{dom_id}-resolve"} thread_id={entry.thread.id} />
                </:actions>
              </.thread_row>
            </div>
            <.more :if={@more.quiet > 0} id="quiet-more" count={@more.quiet} />
          </section>

          <section id="schedules" class="mt-9">
            <.section_title>Blip's schedules</.section_title>
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

  # The first question the thread is still waiting on Blip for, on one line.
  defp asked(entry) do
    case Enum.find(entry.questions, &(&1.status == "asked")) do
      nil -> ""
      question -> ThreadText.one_line(question.question)
    end
  end

  defp thread_path(entry), do: ~p"/projects/#{entry.project.slug}/threads/#{entry.thread.id}"

  slot :inner_block, required: true

  defp section_title(assigns) do
    ~H"""
    <h2 class="text-[11px] font-semibold tracking-wider text-ink-faint uppercase">
      {render_slot(@inner_block)}
    </h2>
    """
  end

  attr :title, :string, required: true
  attr :count, :integer, required: true
  attr :state, :atom, required: true
  slot :inner_block

  # The head of one of Needs you's lists: its mark, title and count, and
  # any action.
  defp subhead(assigns) do
    ~H"""
    <div class="flex min-h-8 items-center gap-2">
      <.state_mark state={@state} class="size-3.5" />
      <h3 class="text-[13px] font-semibold text-ink">{@title}</h3>
      <span class="rounded-full bg-sunken px-1.5 py-px text-[11px] font-medium tabular-nums text-ink-soft">
        {@count}
      </span>
      <div class="ml-auto">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :count, :integer, required: true

  defp more(assigns) do
    ~H"""
    <p id={@id} class="mt-2 pl-4 text-[12.5px] text-ink-faint">{ThreadText.more(@count)}</p>
    """
  end

  attr :id, :string, required: true
  attr :entry, :map, required: true

  # The project and the thread, each linking to its page.
  defp place(assigns) do
    ~H"""
    <div class="flex min-w-0 items-baseline gap-1.5 text-[13.5px]">
      <.link
        navigate={~p"/projects/#{@entry.project.slug}"}
        id={"#{@id}-project"}
        class="max-w-[50%] shrink-0 truncate text-ink-faint transition hover:text-ink"
        title={@entry.project.name}
      >
        {@entry.project.name}
      </.link>
      <span class="text-ink-faint/60">/</span>
      <.link
        navigate={thread_path(@entry)}
        id={"#{@id}-thread"}
        class="min-w-0 truncate font-medium text-ink transition hover:text-accent-strong"
        title={@entry.thread.title}
      >
        {@entry.thread.title}
      </.link>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :entry, :map, required: true
  attr :rest, :global
  slot :detail
  slot :at
  slot :actions

  # A thread's row: its mark, where it is, a line about it, when, and any
  # actions. On a narrow screen the time and actions wrap under the text
  # rather than squeezing it (the text keeps at least 12rem).
  defp thread_row(assigns) do
    ~H"""
    <div
      id={@id}
      class="group flex flex-wrap items-start gap-x-3 gap-y-1.5 rounded-xl border border-line bg-surface px-4 py-3 shadow-xs transition hover:border-line-strong"
      {@rest}
    >
      <span class="mt-1 flex size-3.5 shrink-0 items-center justify-center">
        <.state_mark state={@entry.state} class="size-3.5" />
        <.icon
          :if={@entry.state == :quiet}
          name="hero-pause-circle-micro"
          class="size-3.5 text-ink-faint"
        />
      </span>
      <div class="min-w-0 flex-1 basis-48">
        <.place id={@id} entry={@entry} />
        <p
          :for={detail <- @detail}
          id={"#{@id}-detail"}
          class="mt-0.5 line-clamp-2 text-[13px] leading-relaxed text-ink-faint"
        >
          {render_slot(detail)}
        </p>
      </div>
      <div
        :if={@at != [] or @actions != []}
        class={["ml-auto flex shrink-0 items-center gap-3", @actions == [] && "mt-0.5"]}
      >
        <span :for={at <- @at} class="text-[12px] text-ink-faint">
          {render_slot(at)}
        </span>
        <div :if={@actions != []} class="flex items-center gap-1.5">
          {render_slot(@actions)}
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :thread_id, :string, required: true

  defp resolve(assigns) do
    ~H"""
    <.button
      id={@id}
      size="sm"
      variant="ghost"
      phx-click="resolve"
      phx-value-id={@thread_id}
      title="Take it off this list until it gets a new message"
    >
      Resolve
    </.button>
    """
  end

  attr :id, :string, required: true
  attr :entry, :map, required: true

  # A thread whose last answer asked the owner something.
  defp asked_row(assigns) do
    ~H"""
    <div
      id={@id}
      class="flex flex-wrap items-start gap-x-3 gap-y-1.5 rounded-xl border border-warn/35 bg-surface px-4 py-3 shadow-xs"
    >
      <span class="mt-1 flex size-3.5 shrink-0 items-center justify-center">
        <.state_mark state={:waiting} class="size-3.5" />
      </span>
      <div class="min-w-0 flex-1 basis-48">
        <.place id={@id} entry={@entry} />
        <p
          :if={@entry.thread.last_run_note}
          id={"#{@id}-detail"}
          class="mt-0.5 line-clamp-2 text-[13.5px] leading-relaxed text-ink-soft"
        >
          {@entry.thread.last_run_note}
        </p>
      </div>
      <div class="ml-auto flex shrink-0 items-center gap-1.5">
        <.button navigate={thread_path(@entry)} id={"#{@id}-open"} size="sm">Open</.button>
        <.resolve id={"#{@id}-resolve"} thread_id={@entry.thread.id} />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :row, :map, required: true

  # A question passed to the owner, with its answer form.
  defp question_row(assigns) do
    question = assigns.row.question

    assigns =
      assign(assigns,
        question: question,
        hub?: question.passed_by == "hub" or is_nil(question.wording),
        passed_at: question.passed_at || question.inserted_at
      )

    ~H"""
    <div
      id={@id}
      class="rounded-xl border border-warn/40 bg-surface px-4 py-3.5 shadow-xs"
    >
      <div class="flex items-start gap-3">
        <span class="mt-1 flex size-3.5 shrink-0 items-center justify-center">
          <.state_mark state={:waiting} class="size-3.5" />
        </span>
        <div class="min-w-0 flex-1">
          <div class="flex items-baseline gap-3">
            <.place id={@id} entry={@row.entry} />
            <span :if={@passed_at} class="ml-auto shrink-0 text-[12px] text-ink-faint">
              <.local_time id={"#{@id}-at"} at={@passed_at} />
            </span>
          </div>
          <p
            id={"#{@id}-text"}
            class="mt-1.5 text-[14.5px] leading-relaxed whitespace-pre-line text-ink"
          >
            {if(@hub?, do: @question.question, else: @question.wording)}
          </p>
          <p :if={@hub?} id={"#{@id}-note"} class="mt-1 text-[12.5px] text-ink-faint">
            In the thread's own words. Your answer goes straight to it.
          </p>
          <.form
            for={@row.form}
            id={"#{@id}-form"}
            phx-change="draft"
            phx-submit="answer"
            class="mt-3"
          >
            <input type="hidden" name="question_id" value={@row.id} />
            <.answer_box field={@row.form[:text]} id={"#{@id}-answer"} />
            <div class="mt-2 flex items-center gap-3">
              <p
                :if={@row.error}
                id={"#{@id}-error"}
                class="flex items-center gap-1.5 text-[12.5px] text-bad"
              >
                <.icon name="hero-exclamation-circle-micro" class="size-4 shrink-0" />
                {@row.error}
              </p>
              <.button
                id={"#{@id}-send"}
                type="submit"
                size="sm"
                variant="primary"
                class="ml-auto"
              >
                Send <.icon name="hero-paper-airplane-micro" class="size-4" />
              </.button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end
end
