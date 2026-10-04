defmodule PhotonWeb.BlipLive do
  @moduledoc """
  Blip, floating over every page: the one Blip on screen, and the
  conversation with it. `PhotonWeb.Layouts.app/1` renders it once, sticky,
  so Blip, its panel and the conversation stay put while the page under it
  changes.

  Blip rests in the bottom-right corner, its face showing its mood. Click
  it (or press Ctrl/⌘+J) and it opens into the chat panel, moving into the
  panel's header. The panel floats in the corner, pins to the right as a
  column, or fills the window (`@panel`). The `.BlipDock` hook makes each
  change at once in the browser, animated where the browser can, and then
  tells the server.

  While the panel is closed, Blip speaks up about its answers, failures in
  the conversation, and node work the user started that failed
  (`Photon.Assistant.Notice`): it stretches into a pill with one line, and
  counts what's unread until the panel opens.

  It knows which page is under it (`Photon.Assistant.Page`): on a node
  session's page, the message box offers that session as context for the
  next message.

  What the conversation shows, how live events fold into the in-flight
  answer, and Blip's mood are `Photon.Assistant.Transcript`. The mood comes
  from what is happening now, except for an outcome (a finish or a
  failure), which is held for a moment so it can be seen: `@outcome`,
  cleared by a `{:blip_rest, ref}` timer.
  """

  use PhotonWeb, :live_view

  alias Photon.{Assistant, Markdown, NodeSessions}
  alias Photon.Assistant.{Notice, Page, Transcript}
  alias PhotonCore.Message

  on_mount PhotonWeb.Auth
  on_mount PhotonWeb.Shell

  # How long Blip shows an outcome before going back to what's happening.
  @hold_ms %{done: 2_200, error: 4_000}

  # Closed in the corner; open, floating; pinned to the right; filling the window.
  @panels ~w(closed open pinned full)

  @impl true
  def mount(_params, _session, socket) do
    conversation = Assistant.conversation_id()
    if connected?(socket), do: Assistant.subscribe(conversation)

    entries = Assistant.entries(conversation)
    %{results: results, calls: calls, settled: settled} = Transcript.index(entries)

    socket =
      socket
      |> assign(
        conversation: conversation,
        results: results,
        settled: settled,
        calls: calls,
        empty?: Transcript.empty?(entries),
        live: nil,
        outcome: nil,
        outcome_ref: nil,
        busy: Assistant.busy?(conversation),
        queued: Assistant.queued(conversation),
        mode: "follow_up",
        form: to_form(%{"text" => ""}, as: :message),
        panel: "closed",
        notice: nil,
        unread: 0,
        page: nil,
        page_dismissed: false,
        statuses: Notice.statuses(socket.assigns.shell.sessions)
      )
      |> stream(:entries, Enum.filter(entries, &Transcript.shown?/1))

    {:ok, socket, layout: false}
  end

  ## Events

  @impl true
  def handle_event("send", %{"message" => %{"text" => text}}, socket) do
    case String.trim(text) do
      "" ->
        {:noreply, socket}

      text ->
        {:ok, _} = Assistant.send(text, when_busy: socket.assigns.mode, page: context(socket))

        {:noreply,
         assign(socket, form: to_form(%{"text" => ""}, as: :message), mode: "follow_up")}
    end
  end

  def handle_event("example", %{"text" => text}, socket) do
    handle_event("send", %{"message" => %{"text" => text}}, socket)
  end

  def handle_event("toggle_mode", _params, socket) do
    {:noreply, update(socket, :mode, &if(&1 == "steer", do: "follow_up", else: "steer"))}
  end

  def handle_event("stop", _params, socket) do
    Assistant.stop()
    {:noreply, socket}
  end

  def handle_event("withdraw", %{"id" => id}, socket) do
    Assistant.withdraw(id)
    {:noreply, assign(socket, queued: Assistant.queued(socket.assigns.conversation))}
  end

  # The hook has already changed the panel in the browser. Opening it reads
  # everything unread; only a failure of the user's own work stays, as a bar
  # at the top, since the conversation doesn't show it.
  def handle_event("panel", %{"to" => to}, socket) when to in @panels do
    socket = assign(socket, panel: to)

    if to == "closed",
      do: {:noreply, socket},
      else: {:noreply, assign(socket, unread: 0, notice: kept_open(socket.assigns.notice))}
  end

  # The page under Blip changed (the hook reports each navigation).
  def handle_event("page", %{"path" => path}, socket) when is_binary(path) do
    {:noreply, assign(socket, page: page_at(path), page_dismissed: false)}
  end

  def handle_event("dismiss_page", _params, socket),
    do: {:noreply, assign(socket, page_dismissed: true)}

  def handle_event("dismiss_notice", _params, socket),
    do: {:noreply, assign(socket, notice: nil)}

  defp kept_open(%{kind: :failed} = notice), do: notice
  defp kept_open(_notice), do: nil

  defp page_at(path) do
    with id when is_binary(id) <- Page.session_id(path),
         %{} = session <- NodeSessions.get(id) do
      Page.of_session(session)
    else
      _ -> nil
    end
  end

  # The page the next message goes with, unless the user waved it off.
  defp context(%{assigns: %{page_dismissed: true}}), do: nil
  defp context(socket), do: socket.assigns.page

  ## Updates

  @impl true
  def handle_info(
        {:durable, conversation, changes},
        %{assigns: %{conversation: conversation}} = socket
      ) do
    was_busy = socket.assigns.busy
    busy = Assistant.busy?(conversation)
    socket = Enum.reduce(changes.entries, socket, &add_entry(&2, &1))

    socket =
      socket
      |> assign(queued: Assistant.queued(conversation), busy: busy)
      |> then(&if(busy, do: &1, else: assign(&1, live: nil)))
      |> hold(Transcript.outcome(changes.entries, was_busy, busy))
      |> notify(Notice.from_entries(changes.entries))

    {:noreply, socket}
  end

  def handle_info(
        {:live, conversation, event},
        %{assigns: %{conversation: conversation}} = socket
      ) do
    {:noreply, assign(socket, live: Transcript.live(socket.assigns.live, event))}
  end

  # `PhotonWeb.Shell` has already read the sessions again.
  def handle_info(:node_sessions_changed, socket) do
    sessions = socket.assigns.shell.sessions

    {:noreply,
     socket
     |> notify(Notice.failures(socket.assigns.statuses, sessions))
     |> assign(statuses: Notice.statuses(sessions))}
  end

  # A timer for an outcome a later one replaced finds a different ref, and
  # falls through to the last clause.
  def handle_info({:blip_rest, ref}, %{assigns: %{outcome_ref: ref}} = socket),
    do: {:noreply, assign(socket, outcome: nil, outcome_ref: nil)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # Shows an outcome for a moment; a later one replaces it, except that a
  # finish doesn't cover a failure still being shown.
  defp hold(socket, nil), do: socket
  defp hold(%{assigns: %{outcome: :error}} = socket, :done), do: socket

  defp hold(socket, outcome) do
    ref = make_ref()
    Process.send_after(self(), {:blip_rest, ref}, Map.fetch!(@hold_ms, outcome))
    assign(socket, outcome: outcome, outcome_ref: ref)
  end

  # Closed, Blip says the latest thing and counts them all. Open, the
  # conversation shows its own answers and failures, so only a failure of
  # the user's own work is said. Each notice gets a new ID, so the hook
  # stretches Blip into the pill again even when the words repeat.
  defp notify(socket, []), do: socket

  defp notify(%{assigns: %{panel: "closed"}} = socket, notices) do
    socket
    |> update(:unread, &(&1 + length(notices)))
    |> assign(notice: identify(List.last(notices)))
  end

  defp notify(socket, notices) do
    case Enum.filter(notices, &(&1.kind == :failed)) do
      [] -> socket
      failed -> assign(socket, notice: identify(List.last(failed)))
    end
  end

  defp identify(notice), do: Map.put(notice, :id, System.unique_integer([:positive]))

  # A tool result re-renders the assistant entry whose call it answers.
  defp add_entry(socket, %{kind: "tool_result"} = entry) do
    socket = update(socket, :results, &Transcript.add_result(&1, entry))

    case socket.assigns.calls[Transcript.call_id(entry)] do
      nil -> socket
      parent -> stream_insert(socket, :entries, parent)
    end
  end

  defp add_entry(socket, %{kind: "assistant"} = entry) do
    socket
    |> update(:calls, &Transcript.add_calls(&1, entry))
    |> assign(live: nil, empty?: false)
    |> stream_insert(:entries, entry)
  end

  defp add_entry(socket, entry) do
    socket = settle(socket, entry)

    if Transcript.shown?(entry),
      do: socket |> assign(empty?: false) |> stream_insert(:entries, entry),
      else: socket
  end

  # A node report settles the calls that left its work running, and
  # re-renders the assistant entries that made them.
  defp settle(socket, entry) do
    {settled, call_ids} = Transcript.settle(socket.assigns.settled, socket.assigns.results, entry)

    call_ids
    |> Enum.map(&socket.assigns.calls[&1])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.reduce(assign(socket, settled: settled), &stream_insert(&2, :entries, &1))
  end

  ## Rendering

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        mood:
          Transcript.mood(%{
            outcome: assigns.outcome,
            live: assigns.live,
            working: length(assigns.shell.working),
            busy: assigns.busy
          }),
        context: context(%{assigns: assigns})
      )

    ~H"""
    <div
      id="blip-dock"
      phx-hook=".BlipDock"
      data-panel={@panel}
      data-notice={@notice && @notice.id}
      class="blip-dock group/dock"
    >
      <section id="blip-panel" class="blip-panel" aria-label="Blip">
        <header class="flex h-15 shrink-0 items-center gap-1 border-b border-line pr-2 pl-16">
          <div class="min-w-0 flex-1">
            <p class="text-[15px] leading-tight font-semibold tracking-tight">Blip</p>
            <p id="blip-status" class="truncate text-[12px] text-ink-faint">
              {status_line(@mood, @shell)}
            </p>
          </div>
          <button
            type="button"
            data-blip-action="pin"
            class="blip-tool hidden lg:grid"
            title="Pin to the side"
          >
            <.icon name="hero-view-columns" class="size-[18px]" />
          </button>
          <button type="button" data-blip-action="full" class="blip-tool" title="Fill the window">
            <.icon
              name="hero-arrows-pointing-out"
              class="size-[18px] group-data-[panel=full]/dock:hidden"
            />
            <.icon
              name="hero-arrows-pointing-in"
              class="hidden size-[18px] group-data-[panel=full]/dock:block"
            />
          </button>
          <button
            type="button"
            id="blip-close"
            data-blip-action="close"
            class="blip-tool"
            title="Close (Esc)"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </header>

        <.notice_bar
          :if={@notice && @notice.kind == :failed && @panel != "closed"}
          notice={@notice}
        />

        <div id="conversation" phx-hook=".StickToBottom" class="min-h-0 flex-1 overflow-y-auto">
          <div class="mx-auto w-full max-w-3xl px-4 pt-5 pb-4 sm:px-5">
            <.empty_state :if={@empty?} shell={@shell} />

            <div id="entries" phx-update="stream" class="space-y-5">
              <div :for={{dom_id, entry} <- @streams.entries} id={dom_id} class="animate-rise">
                <.entry entry={entry} results={@results} settled={@settled} />
              </div>
            </div>

            <.live_output
              :if={@live || @mood in [:thinking, :working]}
              live={@live}
              mood={@mood}
              working={@shell.working}
            />
          </div>
        </div>

        <.composer
          :if={@shell.model_ready}
          form={@form}
          busy={@busy}
          mode={@mode}
          queued={@queued}
          context={@context}
        />
        <.sign_in_to_talk :if={!@shell.model_ready} chatgpt={@shell.chatgpt} />
      </section>

      <.pill :if={@notice} notice={@notice} />

      <button
        type="button"
        id="blip-face"
        class="blip-face"
        aria-controls="blip-panel"
        aria-expanded={to_string(@panel != "closed")}
        aria-label={if(@panel == "closed", do: "Open Blip (Ctrl+J)", else: "Blip")}
      >
        <%!-- The one Blip: hover and it notices; click and it wobbles. --%>
        <.blip id="blip-avatar" state={@mood} size={76} interactive />
        <span :if={@unread > 0} id="blip-unread" class="blip-unread">
          {if(@unread > 9, do: "9+", else: @unread)}
        </span>
      </button>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".BlipDock">
      // The panel changes here first, so it's instant and the browser can
      // animate it: the panel grows out of Blip, and Blip moves into its
      // header (a view transition, where the browser has them). The server
      // hears about it after. The attribute is set as a JS command, so
      // patches from the server keep it.
      const KEEP_MS = 6000, AGAIN_MS = 2500

      export default {
        mounted() {
          this.notice = this.el.dataset.notice
          this.mark(this.el.dataset.panel)

          this.el.addEventListener("click", e => {
            const action = e.target.closest("[data-blip-action]")?.dataset.blipAction
            if (action) return this.act(action)
            if (e.target.closest("#blip-face") && this.panel() === "closed") this.go("open")
          })

          this.onKey = e => {
            if ((e.metaKey || e.ctrlKey) && !e.altKey && e.key.toLowerCase() === "j") {
              e.preventDefault()
              this.go(this.panel() === "closed" ? "open" : "closed")
            } else if (e.key === "Escape" && ["open", "full"].includes(this.panel())) {
              this.go("closed")
            }
          }
          document.addEventListener("keydown", this.onKey)

          // Blip shrinks back from the pill when you scroll or swipe, but not
          // when a page scrolls itself to follow new output.
          this.onWheel = () => { if (this.extended && Date.now() - this.extended > 800) this.collapse() }
          document.addEventListener("wheel", this.onWheel, {passive: true, capture: true})
          document.addEventListener("touchmove", this.onWheel, {passive: true, capture: true})

          // Looking at Blip, or at what it's saying, keeps the pill open.
          const face = this.el.querySelector("#blip-face")
          face.addEventListener("pointerenter", () => this.hold())
          face.addEventListener("pointerleave", () => this.release())

          this.reportPage()
          this.onNavigate = () => this.reportPage()
          window.addEventListener("phx:page-loading-stop", this.onNavigate)
        },

        updated() {
          const notice = this.el.dataset.notice
          if (notice && notice !== this.notice && this.panel() === "closed") this.extend()
          this.notice = notice
          const pill = this.pill()
          if (pill && !pill.dataset.blipWatched) {
            pill.dataset.blipWatched = "1"
            pill.addEventListener("pointerenter", () => this.hold())
            pill.addEventListener("pointerleave", () => this.release())
          }
        },

        destroyed() {
          document.removeEventListener("keydown", this.onKey)
          document.removeEventListener("wheel", this.onWheel, {capture: true})
          document.removeEventListener("touchmove", this.onWheel, {capture: true})
          window.removeEventListener("phx:page-loading-stop", this.onNavigate)
          clearTimeout(this.timer)
        },

        panel() { return this.el.dataset.panel },
        pill() { return this.el.querySelector("#blip-pill") },

        act(action) {
          const now = this.panel()
          if (action === "close") this.go("closed")
          if (action === "open") this.go("open")
          if (action === "pin") this.go(now === "pinned" ? "open" : "pinned")
          if (action === "full") this.go(now === "full" ? "open" : "full")
        },

        go(to) {
          const from = this.panel()
          if (from === to) return
          const apply = () => {
            this.js().setAttribute(this.el, "data-panel", to)
            this.mark(to)
            if (to !== "closed") {
              this.collapse()
              const thread = this.el.querySelector("#conversation")
              if (from === "closed" && thread) thread.scrollTop = thread.scrollHeight
            }
          }
          // With reduced motion, app.css keeps the transition to a fade.
          const done = document.startViewTransition
            ? document.startViewTransition(apply).finished
            : Promise.resolve(apply())
          done.finally(() => {
            if (to === "closed") this.el.querySelector("#blip-face")?.focus()
            else if (from === "closed") this.el.querySelector("#composer-input")?.focus()
          })
          this.pushEvent("panel", {to})
        },

        // Pages make room for a pinned panel from this (see app.css).
        mark(panel) { document.documentElement.dataset.blipPanel = panel },

        reportPage() {
          if (location.pathname === this.path) return
          this.path = location.pathname
          this.pushEvent("page", {path: this.path})
        },

        extend() {
          const pill = this.pill()
          if (!pill) return
          this.js().addClass(pill, "is-extended")
          this.extended = Date.now()
          this.release(KEEP_MS)
        },

        collapse() {
          clearTimeout(this.timer)
          this.extended = null
          const pill = this.pill()
          if (pill) this.js().removeClass(pill, "is-extended")
        },

        hold() { clearTimeout(this.timer) },

        release(ms = AGAIN_MS) {
          clearTimeout(this.timer)
          if (this.extended) this.timer = setTimeout(() => this.collapse(), ms)
        }
      }
    </script>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".StickToBottom">
      export default {
        mounted() {
          this.stick = true
          this.el.scrollTop = this.el.scrollHeight
          this.el.addEventListener("scroll", () => {
            this.stick = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 120
          })
          this.observer = new MutationObserver(() => {
            if (this.stick) this.el.scrollTop = this.el.scrollHeight
          })
          this.observer.observe(this.el, {childList: true, subtree: true, characterData: true})
        },
        destroyed() { this.observer.disconnect() }
      }
    </script>
    """
  end

  # The line under Blip's name in the panel header.
  defp status_line(_mood, %{model_ready: false}), do: "Needs a ChatGPT sign-in"
  defp status_line(:thinking, _shell), do: "Thinking"
  defp status_line(:done, _shell), do: "Done"
  defp status_line(:error, _shell), do: "Something failed"

  defp status_line(:working, %{working: [one]}), do: "#{one.node_id} is working on it"
  defp status_line(:working, %{working: working}), do: "#{length(working)} jobs running"
  defp status_line(_mood, %{model: model}), do: "On #{model}"

  attr :notice, :map, required: true

  # Blip stretched into a pill, saying one thing. A failed session links to
  # it; anything else opens the chat.
  defp pill(%{notice: %{kind: :failed}} = assigns) do
    ~H"""
    <.link id="blip-pill" navigate={~p"/sessions/#{@notice.session_id}"} class="blip-pill is-failed">
      <.icon name="hero-exclamation-circle-micro" class="size-4 shrink-0 text-bad" />
      <span class="truncate">{@notice.text}</span>
    </.link>
    """
  end

  defp pill(assigns) do
    ~H"""
    <button
      type="button"
      id="blip-pill"
      data-blip-action="open"
      class={["blip-pill", @notice.kind == :error && "is-failed"]}
    >
      <.icon
        :if={@notice.kind == :error}
        name="hero-exclamation-circle-micro"
        class="size-4 shrink-0 text-bad"
      />
      <span class="truncate">{@notice.text}</span>
    </button>
    """
  end

  attr :notice, :map, required: true

  defp notice_bar(assigns) do
    ~H"""
    <div
      id="blip-notice-bar"
      class="flex shrink-0 items-center gap-2 border-b border-line bg-bad-soft px-4 py-2 text-[13px]"
    >
      <.icon name="hero-exclamation-circle-micro" class="size-4 shrink-0 text-bad" />
      <span class="min-w-0 flex-1 truncate">{@notice.text}</span>
      <.link
        navigate={~p"/sessions/#{@notice.session_id}"}
        class="shrink-0 rounded px-1.5 py-0.5 font-medium text-accent-strong hover:bg-surface/60"
      >
        Open
      </.link>
      <button
        type="button"
        phx-click="dismiss_notice"
        class="shrink-0 rounded p-0.5 text-ink-faint hover:text-ink"
        title="Dismiss"
      >
        <.icon name="hero-x-mark-micro" class="size-4" />
      </button>
    </div>
    """
  end

  attr :shell, :map, required: true

  defp empty_state(assigns) do
    online = Enum.filter(assigns.shell.nodes, & &1.online)
    assigns = assign(assigns, online: online, first: List.first(online))

    ~H"""
    <div id="empty-state" class="pt-6 pb-8">
      <h2 class="text-xl font-semibold tracking-tight">Hi. I'm Blip.</h2>
      <p class="mt-2 text-[14.5px] leading-relaxed text-ink-soft">
        I'm a photon living on this hub. I can't run commands myself, so I hand work to your machines and tell you what they actually did.
      </p>
      <p :if={!@shell.model_ready} class="mt-3 text-sm text-ink-soft">
        First I need a model to think with. Sign in with ChatGPT and I'll use your plan.
      </p>
      <p :if={@shell.model_ready and @online == []} class="mt-3 text-sm text-ink-faint">
        No machines yet, so I have nowhere to send work.
        <.link navigate={~p"/nodes"} class="text-accent-strong underline underline-offset-2">Add one</.link>
        first.
      </p>
      <div :if={@shell.model_ready} class="mt-5 flex flex-col items-start gap-2">
        <button
          :for={example <- examples(@first && @first.id)}
          phx-click="example"
          phx-value-text={example}
          class="rounded-2xl border border-line bg-surface px-3.5 py-1.5 text-left text-[13px] text-ink-soft shadow-xs transition hover:-translate-y-px hover:border-accent/40 hover:text-ink"
        >
          {example}
        </button>
      </div>
    </div>
    """
  end

  defp examples(node) do
    on = if node, do: " on #{node}", else: ""

    [
      "Which of my machines are online?",
      "How much disk space is free#{on}?",
      "Check#{on} for anything using a lot of CPU",
      "Every morning at 8, check that my machines are healthy"
    ]
  end

  attr :entry, :map, required: true
  attr :results, :map, required: true
  attr :settled, :map, required: true

  defp entry(%{entry: %{kind: "user"}} = assigns) do
    source = assigns.entry.data["source"] || %{}

    assigns =
      assign(assigns,
        source: source,
        text: Transcript.typed(Message.text_of(assigns.entry.data["message"]), source)
      )

    ~H"""
    <%= case @source["kind"] do %>
      <% "node_report" -> %>
        <.report source={@source} text={@text} />
      <% "routine" -> %>
        <div class="flex items-start gap-3 text-sm">
          <span class="mt-0.5 grid size-7 shrink-0 place-items-center rounded-full bg-sunken text-ink-faint">
            <.icon name="hero-clock" class="size-4" />
          </span>
          <div class="min-w-0 pt-1">
            <span class="text-[11px] font-semibold tracking-wider text-ink-faint uppercase">Scheduled</span>
            <p class="mt-0.5 text-ink-soft">{String.replace_prefix(@text, "[Scheduled] ", "")}</p>
          </div>
        </div>
      <% _ -> %>
        <div class="flex flex-col items-end gap-1 pl-10">
          <span :if={@source["page"]} class="text-[11px] text-ink-faint">
            About {Page.label(@source["page"])}
          </span>
          <div class="max-w-full rounded-2xl rounded-br-md bg-sunken px-3.5 py-2 text-[14.5px] leading-relaxed text-ink ring-1 ring-line">
            <span phx-no-format class="whitespace-pre-wrap">{@text}</span>
          </div>
        </div>
    <% end %>
    """
  end

  defp entry(%{entry: %{kind: "assistant"}} = assigns) do
    message = assigns.entry.data["message"]
    assigns = assign(assigns, text: Message.text_of(message), calls: Message.tool_calls(message))

    ~H"""
    <div class="min-w-0 space-y-2.5">
      <div :if={@text != ""} class="markdown-body text-ink">{raw(Markdown.to_html(@text))}</div>
      <div :if={@calls != []} class="space-y-1.5">
        <.action
          :for={call <- @calls}
          call={call}
          result={@results[call["id"]]}
          settled={@settled[call["id"]]}
        />
      </div>
    </div>
    """
  end

  defp entry(%{entry: %{kind: "error"}} = assigns) do
    assigns = assign(assigns, quiet: Transcript.quiet?(assigns.entry.data))

    ~H"""
    <div class={[
      "flex items-start gap-2 rounded-xl px-3.5 py-2.5 text-sm",
      if(@quiet, do: "bg-sunken text-ink-soft", else: "bg-bad-soft text-ink")
    ]}>
      <.icon
        name={
          cond do
            @entry.data["notice"] -> "hero-clock"
            @quiet -> "hero-stop-circle"
            true -> "hero-exclamation-triangle"
          end
        }
        class={["mt-0.5 size-4 shrink-0", if(@quiet, do: "text-ink-faint", else: "text-bad")]}
      />
      <span class="leading-relaxed">{@entry.data["message"]}</span>
    </div>
    """
  end

  defp entry(%{entry: %{kind: "reset"}} = assigns) do
    ~H"""
    <div class="flex items-center gap-3 py-2 text-[11px] font-semibold tracking-wider text-ink-faint uppercase">
      <span class="h-px flex-1 bg-line" /> Fresh context <span class="h-px flex-1 bg-line" />
    </div>
    """
  end

  attr :source, :map, required: true
  attr :text, :string, required: true

  defp report(assigns) do
    body = assigns.text |> String.split("\n", parts: 2) |> Enum.at(1, "") |> String.trim()
    assigns = assign(assigns, body: body)

    ~H"""
    <div class="overflow-hidden rounded-xl border border-line bg-surface shadow-xs">
      <div class="flex items-center gap-2 border-b border-line bg-sunken/60 px-3.5 py-2 text-[13px]">
        <.icon
          name={if(@source["failed"], do: "hero-exclamation-circle", else: "hero-check-circle")}
          class={["size-4", if(@source["failed"], do: "text-bad", else: "text-ok")]}
        />
        <span class="font-medium">{@source["node"]}</span>
        <span class="min-w-0 flex-1 truncate text-ink-soft">{@source["title"]}</span>
        <.link
          navigate={~p"/sessions/#{@source["session_id"]}"}
          class="shrink-0 text-[12px] text-accent-strong hover:underline"
        >
          Open session
        </.link>
      </div>
      <div class="markdown-body max-h-80 overflow-y-auto px-4 py-3 text-[14px] text-ink-soft">
        {raw(Markdown.to_html(if(@body == "", do: @text, else: @body)))}
      </div>
    </div>
    """
  end

  attr :call, :map, required: true
  attr :result, :map, default: nil
  attr :settled, :atom, default: nil

  defp action(assigns) do
    args =
      case Message.arguments(assigns.call) do
        {:ok, args} -> args
        _ -> %{}
      end

    details = (assigns.result && assigns.result["details"]) || %{}
    status = Transcript.action_status(assigns.result, details, assigns.settled)

    assigns =
      assign(assigns,
        args: args,
        details: details,
        status: status,
        label: action_label(assigns.call["name"], args),
        output: assigns.result && Message.text_of(assigns.result["message"])
      )

    ~H"""
    <details
      id={"action-#{@call["id"]}"}
      data-status={@status}
      class="group rounded-xl border border-line bg-surface shadow-xs open:shadow-sm"
    >
      <summary class="flex cursor-pointer list-none items-center gap-2.5 px-3 py-2 text-[13px] select-none">
        <span class={[
          "grid size-6 shrink-0 place-items-center rounded-md",
          @status in [:running, :pending] && "bg-accent-soft text-accent-strong",
          @status == :done && "bg-ok-soft text-ok",
          @status == :error && "bg-bad-soft text-bad",
          @status == :stopped && "bg-sunken text-ink-faint"
        ]}>
          <.spinner :if={@status in [:running, :pending]} class="size-3.5" />
          <.icon :if={@status == :done} name={action_icon(@call["name"])} class="size-3.5" />
          <.icon :if={@status == :error} name="hero-exclamation-triangle-micro" class="size-3.5" />
          <.icon :if={@status == :stopped} name="hero-stop-micro" class="size-3.5" />
        </span>
        <span class="min-w-0 flex-1 truncate text-ink-soft">{@label}</span>
        <span :if={@status == :running} class="shrink-0 text-[11px] text-accent-strong">working on it</span>
        <.link
          :if={@details["session_id"]}
          navigate={~p"/sessions/#{@details["session_id"]}"}
          class="shrink-0 rounded px-1.5 py-0.5 text-[12px] text-accent-strong hover:bg-accent-soft"
        >
          Open
        </.link>
        <.icon
          name="hero-chevron-down-micro"
          class="size-4 shrink-0 text-ink-faint transition group-open:rotate-180"
        />
      </summary>
      <div class="border-t border-line px-3.5 py-2.5">
        <pre class="max-h-72 overflow-auto font-mono text-[12px] leading-relaxed whitespace-pre-wrap text-ink-soft">{@output || "Waiting for the result."}</pre>
      </div>
    </details>
    """
  end

  defp action_label("run_on_node", args),
    do: "#{args["node"]}: #{args["title"] || truncate(args["task"])}"

  defp action_label("message_node_session", args),
    do: "Message to #{args["session_id"]}: #{truncate(args["message"])}"

  defp action_label("check_node_session", args), do: "Looked at #{args["session_id"]}"
  defp action_label("stop_node_session", args), do: "Stopped #{args["session_id"]}"
  defp action_label("list_nodes", _), do: "Checked your machines"

  defp action_label("update_memory", args),
    do: "Memory: #{args["action"]} #{truncate(args["text"])}"

  defp action_label("schedule", args), do: "Scheduled: #{truncate(args["prompt"])}"
  defp action_label("list_schedules", _), do: "Checked the schedule"
  defp action_label("cancel_schedule", args), do: "Cancelled #{args["schedule_id"]}"
  defp action_label(name, _), do: name

  defp action_icon("run_on_node"), do: "hero-command-line-micro"
  defp action_icon("message_node_session"), do: "hero-chat-bubble-left-micro"
  defp action_icon("list_nodes"), do: "hero-server-stack-micro"
  defp action_icon("update_memory"), do: "hero-bookmark-micro"

  defp action_icon(name) when name in ~w(schedule list_schedules cancel_schedule),
    do: "hero-clock-micro"

  defp action_icon(_), do: "hero-check-micro"

  defp truncate(nil), do: ""

  defp truncate(text) do
    text = text |> String.replace(~r/\s+/, " ") |> String.trim()
    if String.length(text) > 90, do: String.slice(text, 0, 87) <> "...", else: text
  end

  attr :live, :map, required: true
  attr :mood, :atom, required: true
  attr :working, :list, required: true

  # What Blip is up to between answers: waiting on a run, or node work still
  # going. Blip itself shows it too, in the header; there's no second Blip here.
  defp live_output(%{live: nil} = assigns) do
    ~H"""
    <div id="live-output" data-mood={@mood} class="mt-5">
      <div :if={@mood == :thinking} class="flex h-6 items-center"><.thinking /></div>
      <div :if={@mood == :working} class="space-y-1">
        <p
          :for={s <- @working}
          id={"live-work-#{s.id}"}
          class="flex items-center gap-2 text-[13px] text-ink-soft"
        >
          <span class="text-accent-strong"><.spinner class="size-3.5" /></span>
          <span class="min-w-0 truncate">
            <span class="font-medium text-ink">{s.node_id}</span> is working on {s.title}
          </span>
          <.link
            navigate={~p"/sessions/#{s.id}"}
            class="shrink-0 rounded px-1.5 py-0.5 text-[12px] text-accent-strong hover:bg-accent-soft"
          >
            Open
          </.link>
        </p>
      </div>
    </div>
    """
  end

  defp live_output(assigns) do
    ~H"""
    <div id="live-output" data-mood={@mood} class="mt-5 space-y-2">
      <p
        :if={@live.retry}
        class="flex items-center gap-2 rounded-lg bg-warn-soft px-3 py-2 text-[13px] text-ink-soft"
      >
        <.icon name="hero-arrow-path" class="size-4 animate-spin text-warn" /> {@live.retry}
      </p>
      <p
        :if={@live.reasoning != "" and @live.text == ""}
        class="line-clamp-3 text-[13px] leading-relaxed text-ink-faint italic"
      >
        {@live.reasoning |> String.slice(-400, 400)}
      </p>
      <div :if={@live.text != ""} class="markdown-body streaming-caret text-ink">
        {raw(Markdown.to_html(@live.text))}
      </div>
      <div
        :for={{_index, name} <- @live.tools}
        class="flex items-center gap-2 text-[13px] text-ink-faint"
      >
        <.spinner class="size-3.5" /> Preparing {name}
      </div>
      <div
        :if={
          @live.text == "" and @live.reasoning == "" and @live.tools == %{} and is_nil(@live.retry)
        }
        class="flex h-6 items-center"
      >
        <.thinking />
      </div>
    </div>
    """
  end

  defp thinking(assigns) do
    ~H"""
    <div class="flex items-center gap-1.5 text-ink-faint" aria-label="Thinking">
      <span class="size-1.5 animate-breathe rounded-full bg-current" />
      <span class="size-1.5 animate-breathe rounded-full bg-current [animation-delay:0.2s]" />
      <span class="size-1.5 animate-breathe rounded-full bg-current [animation-delay:0.4s]" />
    </div>
    """
  end

  attr :chatgpt, :map, required: true

  # In place of the composer until there's a model to talk to.
  defp sign_in_to_talk(assigns) do
    ~H"""
    <div class="shrink-0 border-t border-line px-4 pt-3 pb-4">
      <div
        id="sign-in-to-talk"
        class="mx-auto flex w-full max-w-3xl flex-wrap items-center justify-between gap-3 rounded-2xl border border-line bg-canvas px-4 py-3"
      >
        <p class="text-[14px] text-ink-soft">
          {if(@chatgpt.state == :signed_in,
            do: "Photon isn't allowed to use your ChatGPT plan yet.",
            else: "Blip needs a ChatGPT sign-in to think."
          )}
        </p>
        <.button navigate={~p"/settings"} variant="primary" size="sm">
          {if(@chatgpt.state == :signed_in, do: "Fix in Settings", else: "Sign in with ChatGPT")}
        </.button>
      </div>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :busy, :boolean, required: true
  attr :mode, :string, required: true
  attr :queued, :list, required: true
  attr :context, :map, default: nil, doc: "the page the next message goes with"

  defp composer(assigns) do
    ~H"""
    <div class="shrink-0 px-3 pt-1 pb-3 sm:px-4 sm:pb-4">
      <div class="mx-auto w-full max-w-3xl">
        <div :if={@queued != []} id="queued" class="mb-2 flex flex-wrap gap-1.5">
          <span
            :for={s <- @queued}
            id={"queued-#{s.id}"}
            class="flex max-w-full items-center gap-1.5 rounded-full border border-line bg-surface py-1 pr-1 pl-3 text-[12px] text-ink-soft"
          >
            <span class="font-medium text-ink-faint">{if(s.mode == "steer", do: "Steer", else: "Next")}</span>
            <span class="max-w-60 truncate">
              {Transcript.typed(Message.text_of(s.content["parts"]), s.content["source"])}
            </span>
            <button
              phx-click="withdraw"
              phx-value-id={s.id}
              class="rounded-full p-0.5 hover:bg-sunken"
              title="Withdraw"
            >
              <.icon name="hero-x-mark-micro" class="size-3.5" />
            </button>
          </span>
        </div>

        <.form
          for={@form}
          id="composer"
          phx-submit="send"
          class="rounded-2xl border border-line bg-canvas transition focus-within:border-accent/60 focus-within:bg-surface focus-within:shadow-md focus-within:shadow-accent/10"
        >
          <div :if={@context} class="flex px-2.5 pt-2.5">
            <span
              id="page-chip"
              class="flex max-w-full items-center gap-1.5 rounded-lg bg-accent-soft py-1 pr-1 pl-2 text-[12px] text-ink-soft"
              title="Blip sees this with your message"
            >
              <.icon name="hero-eye-micro" class="size-3.5 shrink-0 text-accent-strong" />
              <span class="min-w-0 truncate">About {Page.label(@context)}</span>
              <button
                type="button"
                id="page-chip-dismiss"
                phx-click="dismiss_page"
                class="shrink-0 rounded p-0.5 text-ink-faint hover:bg-surface/70 hover:text-ink"
                title="Don't include this page"
              >
                <.icon name="hero-x-mark-micro" class="size-3.5" />
              </button>
            </span>
          </div>
          <textarea
            id="composer-input"
            name={@form[:text].name}
            phx-hook=".Composer"
            rows="1"
            placeholder={if(@busy, do: "Add to the conversation...", else: "Ask Blip anything...")}
            class="block max-h-60 min-h-11 w-full resize-none bg-transparent px-3.5 pt-2.5 pb-1 text-[14.5px] leading-relaxed text-ink outline-none placeholder:text-ink-faint"
          >{@form[:text].value}</textarea>
          <div class="flex items-center gap-2 px-2 pb-2">
            <button
              :if={@busy}
              type="button"
              id="mode-toggle"
              phx-click="toggle_mode"
              class={[
                "rounded-full px-2.5 py-1 text-[12px] transition",
                @mode == "steer" && "bg-accent-soft font-medium text-accent-strong",
                @mode != "steer" && "text-ink-faint hover:bg-sunken hover:text-ink-soft"
              ]}
              title="Steer joins the current work after its next step. Otherwise your message waits for the current answer."
            >
              {if(@mode == "steer", do: "Steer current work", else: "Send after this answer")}
            </button>
            <span class="flex-1" />
            <.button
              :if={@busy}
              type="button"
              id="stop"
              variant="secondary"
              size="sm"
              phx-click="stop"
            >
              <.icon name="hero-stop-solid" class="size-3.5" /> Stop
            </.button>
            <.button
              type="submit"
              id="send"
              variant="primary"
              size="sm"
              class="size-8 rounded-full px-0"
              title="Send"
            >
              <.icon name="hero-arrow-up" class="size-4" />
            </.button>
          </div>
        </.form>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Composer">
        export default {
          mounted() {
            const grow = () => {
              this.el.style.height = "auto"
              this.el.style.height = Math.min(this.el.scrollHeight, 240) + "px"
            }
            this.el.addEventListener("input", grow)
            this.el.addEventListener("keydown", e => {
              if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
                e.preventDefault()
                if (this.el.value.trim() !== "") this.el.form.requestSubmit()
              }
            })
            this.el.form.addEventListener("submit", () => setTimeout(() => { this.el.value = ""; grow() }, 0))
            grow()
          }
        }
      </script>
    </div>
    """
  end
end
