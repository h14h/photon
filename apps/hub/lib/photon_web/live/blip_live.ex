defmodule PhotonWeb.BlipLive do
  @moduledoc """
  Blip, floating over every page: the one Blip on screen, and the
  conversation with it. `PhotonWeb.Layouts.app/1` renders it once, sticky,
  so Blip, its panel and the conversation stay put while the page under it
  changes.

  Blip rests in the bottom-right corner, its face showing its mood. Click
  it (or press Ctrl/⌘+J) and it opens into the chat panel, moving into the
  panel's header. The panel floats in the corner, pins to the right as a
  column, or fills the window (`@panel`). Esc or a click outside closes a
  floating panel; a pinned one stays. The `.BlipDock` hook makes each
  change at once in the browser, animated where the browser can, and then
  tells the server.

  While the panel is closed, Blip speaks up about its answers and failures
  in the conversation (`Photon.Assistant.Notice`), in a speech bubble above
  it holding the whole first paragraph (`@bubbles`, newest first). A new
  bubble pushes the one before it up and out, except a thread's question
  for the owner, which stays until it is dismissed or read, so what Blip
  says after passing it on doesn't hide it. Each can be dismissed (×, or
  Esc for all), and goes by itself once there's been time to read it. Blip
  counts what's unread until the panel opens.

  It knows which page is under it: the `.BlipDock` hook reports each path
  the browser shows (`page`), again after a reconnect (a fresh mount starts
  with no page), and on a page inside a project (the project,
  a context file, a new thread, a thread) `Photon.Assistant.page_at/1`
  gives the page (`@page`). The message box shows it as a chip, "About
  Garden / Fix the pump"; its × leaves it out (`@page_dismissed`, until
  the next page). When that project changes (`{:projects_changed, id}`,
  through `PhotonWeb.Shell`: a new name, or a thread's new title), the
  page is read again from its path (`@page_path`), so the chip keeps up. A message sent with the chip goes with the page, and
  the model sees a note of it in front of the message.

  A thread's question with the owner shows in the conversation as a card
  (`PhotonWeb.ConversationComponents.question_card/1`). Its `Answer` puts
  a reply chip on the message box in place of the page chip (`@reply`,
  "Answering Fix the pump", × to drop it): what is sent with it goes to
  `Photon.Assistant.answer/2`, straight to the thread, instead of to
  Blip. A refused answer (already answered elsewhere, say) shows its
  reason above the box (`@reply_error`) and gives back what was typed.
  The chip goes when its question is answered or withdrawn. Where each
  question stands is `@questions`, which `PhotonWeb.ConversationView`
  folds from the conversation, the answers still queued included, so a
  card stops offering `Answer` as soon as the answer is sent, even while
  Blip is busy. On mount, the rows of the questions that fold as open
  close any that were settled where the conversation doesn't show it. Only a question that is open on the page takes a reply:
  the ID comes from the browser.

  Threads show under their current titles: the panel reads the titles of
  the threads the conversation names when it mounts, when new entries
  name others, and again on every `{:projects_changed, _}` (a thread
  named after its first run, or renamed), and the lines, cards, chips
  and bubbles that name a thread re-render with its new title
  (`@titles`, see `PhotonWeb.ConversationView`).

  The conversation is shared with a project's thread page.
  `PhotonWeb.ConversationComponents` renders it: the entries, each tool
  call inside the answer that made it, a running call's output tail, the
  images calls returned, the in-flight answer and the composer. Blip's use
  no ID prefix, and its images load from
  `PhotonWeb.ConversationImageController`'s Blip route.
  `PhotonWeb.ConversationView` folds the conversation's commits and live
  events into this page's assigns. Only the dock, panel, bubbles, unread
  count, empty state and mood are Blip's own.

  What the conversation shows, how live events fold into the in-flight
  answer and the running calls' output, and Blip's mood are
  `Photon.Transcript`. The mood comes from what is happening
  now, except for an outcome (a finish or a failure), which is held for a
  moment so it can be seen: `@outcome`, cleared by a `{:blip_rest, ref}`
  timer.
  """

  use PhotonWeb, :live_view

  import PhotonWeb.ConversationComponents

  alias Photon.{Assistant, Markdown, Questions, Threads, Transcript}
  alias Photon.Assistant.Notice
  alias PhotonWeb.ConversationView

  on_mount PhotonWeb.Auth
  on_mount PhotonWeb.Shell

  # How long Blip shows an outcome before going back to what's happening.
  @hold_ms %{done: 2_200, error: 4_000}

  # Closed in the corner; open, floating; pinned to the right; filling the window.
  @panels ~w(closed open pinned full)

  # How long a bubble on its way out takes to fade (see .blip-bubble in app.css).
  @fade_ms 450

  @impl true
  def mount(_params, _session, socket) do
    conversation = Assistant.conversation_id()
    if connected?(socket), do: Assistant.subscribe(conversation)
    entries = Assistant.entries(conversation)
    queued = Assistant.queued(conversation)
    # Where the conversation's runs stand, so a reply in a run already
    # under way is judged by who asked for that run.
    {_said, notice_state} = Notice.scan(entries, Notice.initial())
    named = (entries ++ queued) |> Enum.flat_map(&Transcript.thread_ids/1) |> Enum.uniq()

    socket =
      socket
      |> assign(
        conversation: conversation,
        outcome: nil,
        outcome_ref: nil,
        panel: "closed",
        bubbles: [],
        unread: 0,
        page: nil,
        page_path: nil,
        page_dismissed: false,
        reply: nil,
        reply_error: nil,
        notice_state: notice_state
      )
      |> ConversationView.mount_conversation(entries,
        busy: Assistant.busy?(conversation),
        queued: queued,
        titles: read_titles(named)
      )

    open = ConversationView.open_questions(socket)
    socket = ConversationView.close_questions(socket, Questions.get_many(open))
    {:ok, socket, layout: false}
  end

  ## Events

  @impl true
  def handle_event("send", %{"message" => %{"text" => text}}, socket) do
    case {String.trim(text), socket.assigns.reply} do
      {"", _reply} ->
        {:noreply, socket}

      {_text, %{id: id}} ->
        {:noreply, answer(socket, id, text)}

      {text, nil} ->
        {:ok, _} = Assistant.send(text, when_busy: socket.assigns.mode, page: context(socket))
        {:noreply, ConversationView.reset_form(socket)}
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
  # everything unread and the bubbles go, since the conversation shows them.
  def handle_event("panel", %{"to" => "closed"}, socket),
    do: {:noreply, assign(socket, panel: "closed")}

  def handle_event("panel", %{"to" => to}, socket) when to in @panels,
    do: {:noreply, assign(socket, panel: to, unread: 0, bubbles: [])}

  # The × on a bubble, or its time to read it running out.
  def handle_event("dismiss_bubble", %{"id" => id}, socket),
    do: {:noreply, leave(socket, &(&1.id == id))}

  # Esc, with the panel closed.
  def handle_event("dismiss_bubbles", _params, socket),
    do: {:noreply, leave(socket, fn _bubble -> true end)}

  # The page under Blip changed (the hook reports each navigation).
  def handle_event("page", %{"path" => path}, socket) when is_binary(path) do
    {:noreply,
     assign(socket, page: Assistant.page_at(path), page_path: path, page_dismissed: false)}
  end

  # The × on the page chip: the next messages go without it, until the next page.
  def handle_event("dismiss_page", _params, socket),
    do: {:noreply, assign(socket, page_dismissed: true)}

  # A question card's Answer: the next message answers that question.
  def handle_event("reply", %{"id" => id}, socket) do
    case socket.assigns.questions[id] do
      %{status: :open} = question ->
        reply = %{id: id, title: question.title, thread_id: question.thread_id}
        {:noreply, assign(socket, reply: reply, reply_error: nil)}

      _closed_or_unknown ->
        {:noreply, socket}
    end
  end

  # The × on the reply chip: the next message goes to Blip again.
  def handle_event("dismiss_reply", _params, socket),
    do: {:noreply, assign(socket, reply: nil, reply_error: nil)}

  # The answer goes straight to the thread. A refusal keeps what was typed,
  # in the box and in the browser, which empties the box as it sends.
  defp answer(socket, id, text) do
    case Assistant.answer(id, text) do
      {:ok, _question} ->
        socket |> assign(reply: nil, reply_error: nil) |> ConversationView.reset_form()

      {:error, message} ->
        socket
        |> assign(reply_error: message, form: to_form(%{"text" => text}, as: :message))
        |> push_event("composer:restore", %{id: "composer-input", text: text})
    end
  end

  # The reply chip goes once its question is no longer open.
  defp keep_reply(%{assigns: %{reply: %{id: id}}} = socket) do
    case socket.assigns.questions[id] do
      %{status: :open} -> socket
      _closed -> assign(socket, reply: nil, reply_error: nil)
    end
  end

  defp keep_reply(socket), do: socket

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
    queued = Assistant.queued(conversation)
    {notices, notice_state} = Notice.scan(changes.entries, socket.assigns.notice_state)

    socket =
      socket
      |> title_new(changes.entries ++ queued)
      |> ConversationView.apply_changes(changes, busy, queued)
      |> keep_reply()
      |> hold(Transcript.outcome(changes.entries, was_busy, busy))
      |> assign(notice_state: notice_state)
      |> notify(notices)

    {:noreply, socket}
  end

  # A running call's output, or the in-flight answer.
  def handle_info(
        {:live, conversation, event},
        %{assigns: %{conversation: conversation}} = socket
      ),
      do: {:noreply, ConversationView.apply_live(socket, event)}

  # A project changed (its name, a thread's title, a run): the threads
  # the conversation names are read again, so a thread named or renamed
  # since reads its new title; on the project on screen, the chip reads
  # the page again. Through PhotonWeb.Shell's subscription. It is one
  # read of the named threads by ID however often projects change (rule
  # 73), and it re-renders only the entries whose thread's title changed.
  def handle_info({:projects_changed, id}, socket) do
    titles = socket |> ConversationView.thread_ids() |> read_titles()
    socket = ConversationView.put_titles(socket, titles)

    case socket.assigns.page do
      %{"project_id" => ^id} ->
        {:noreply, assign(socket, page: Assistant.page_at(socket.assigns.page_path))}

      _other_page ->
        {:noreply, socket}
    end
  end

  def handle_info({:bubble_gone, id}, socket),
    do:
      {:noreply, update(socket, :bubbles, fn bubbles -> Enum.reject(bubbles, &(&1.id == id)) end)}

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

  # Closed, Blip says the latest thing in a bubble, pushing the one before it
  # up and out, and counts them all. A thread's question stays, whatever
  # Blip says after it, until it is dismissed or its time runs out; each
  # question gets its own bubble. Open, the conversation shows its own
  # answers, failures and questions, so there's nothing more to say.
  defp notify(%{assigns: %{panel: "closed"}} = socket, [_ | _] = notices) do
    said = notices |> said() |> Enum.map(&as_bubble/1) |> Enum.reverse()

    socket
    |> update(:unread, &(&1 + length(notices)))
    |> leave(&(&1.kind != :question))
    |> update(:bubbles, &(said ++ &1))
  end

  defp notify(socket, _notices), do: socket

  # What of a batch gets a bubble, in order: each question, and the last
  # of the rest.
  defp said(notices) do
    {questions, others} = Enum.split_with(notices, &(&1.kind == :question))
    questions ++ Enum.take(others, -1)
  end

  defp as_bubble(notice),
    do:
      Map.merge(notice, %{
        id: Integer.to_string(System.unique_integer([:positive])),
        leaving: false
      })

  # Reads the titles of the threads new entries or queued messages name,
  # before they are shown.
  defp title_new(socket, items) do
    named = ConversationView.untitled(socket, items)
    ConversationView.put_titles(socket, read_titles(named))
  end

  # The current titles of threads `ids`, nil for those that are gone.
  defp read_titles([]), do: %{}
  defp read_titles(ids), do: Map.merge(Map.new(ids, &{&1, nil}), Threads.titles(ids))

  # The bubbles `which` picks fade out, and go once they have.
  defp leave(socket, which),
    do: update(socket, :bubbles, fn bubbles -> Enum.map(bubbles, &fade(&1, which)) end)

  defp fade(%{leaving: true} = bubble, _which), do: bubble

  defp fade(bubble, which) do
    if which.(bubble) do
      Process.send_after(self(), {:bubble_gone, bubble.id}, @fade_ms)
      %{bubble | leaving: true}
    else
      bubble
    end
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
            busy: assigns.busy
          })
      )

    ~H"""
    <div
      id="blip-dock"
      phx-hook=".BlipDock"
      data-panel={@panel}
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

        <div id="conversation" phx-hook="PinToBottom" class="min-h-0 flex-1 overflow-y-auto">
          <div class="mx-auto w-full max-w-3xl px-4 pt-5 pb-4 sm:px-5">
            <.empty_state :if={@empty?} shell={@shell} />

            <div id="entries" phx-update="stream" class="space-y-5">
              <%!-- An answer arrives already shown, streamed in: no rise. --%>
              <div
                :for={{dom_id, entry} <- @streams.entries}
                id={dom_id}
                class={entry.kind != "assistant" && "animate-rise"}
              >
                <.entry
                  entry={entry}
                  results={@results}
                  outputs={@outputs}
                  questions={@questions}
                  titles={@titles}
                  image_path={&image_path/2}
                />
              </div>
            </div>

            <.live_output :if={@live || @mood == :thinking} live={@live} shown={@shown} mood={@mood} />
          </div>
          <.jump_to_latest />
        </div>

        <.composer
          :if={@shell.model_ready}
          form={@form}
          busy={@busy}
          mode={@mode}
          queued={@queued}
          titles={@titles}
          placeholder={
            if(@reply, do: "Your answer goes straight to the thread", else: "Ask Blip anything...")
          }
        >
          <:above :if={@reply_error}>
            <p
              id="reply-error"
              class="mb-2 flex items-start gap-1.5 rounded-lg bg-bad-soft px-3 py-2 text-[12.5px] text-ink"
            >
              <.icon name="hero-exclamation-circle-micro" class="mt-px size-4 shrink-0 text-bad" />
              {@reply_error}
            </p>
          </:above>
          <:context :if={@reply}>
            <.reply_chip reply={@reply} titles={@titles} />
          </:context>
          <:context :if={!@reply && @page && !@page_dismissed}>
            <.page_chip page={@page} />
          </:context>
        </.composer>
        <.sign_in_to_talk :if={!@shell.model_ready} chatgpt={@shell.chatgpt} />
      </section>

      <div id="blip-bubbles" class="blip-bubbles" aria-live="polite">
        <%!-- Newest last, nearest Blip. --%>
        <.bubble :for={bubble <- Enum.reverse(@bubbles)} bubble={bubble} titles={@titles} />
      </div>

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
      // hears about it at once. The browser applies the change a frame
      // later, so the hook keeps the state itself (this.state) rather than
      // reading it back from the page. The attribute is set as a JS command,
      // so patches from the server keep it.
      //
      // It also times the speech bubbles: each stays long enough to read
      // (about 240 words a minute, after a moment to look up), then asks the
      // server to let it go. Hovering a bubble, or Blip, holds them all.
      const READ_MIN_MS = 6000, READ_MAX_MS = 20000, MS_PER_WORD = 250, AGAIN_MS = 2000

      export default {
        mounted() {
          this.state = this.el.dataset.panel
          this.timers = new Map()
          this.held = false
          this.mark(this.state)

          this.el.addEventListener("click", e => {
            const dismiss = e.target.closest("[data-bubble-dismiss]")
            if (dismiss) return this.dismiss(dismiss.dataset.bubbleDismiss)
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
            } else if (e.key === "Escape" && this.panel() === "closed" && this.timers.size > 0) {
              this.dismissAll()
            }
          }
          document.addEventListener("keydown", this.onKey)

          // A click outside the floating panel closes it, like a dialog's
          // backdrop. Pinned stays: it's a column you work beside. Focus
          // stays wherever the click put it.
          this.onOutside = e => {
            if (["open", "full"].includes(this.state) && !this.el.contains(e.target)) {
              this.go("closed", {refocus: false})
            }
          }
          document.addEventListener("pointerdown", this.onOutside, true)

          for (const el of [this.el.querySelector("#blip-face"), this.el.querySelector("#blip-bubbles")]) {
            el.addEventListener("pointerenter", () => this.hold())
            el.addEventListener("pointerleave", () => this.release())
          }
          this.schedule()

          // The page under Blip, so the message box can offer it as context.
          this.reportPage()
          this.onNavigate = () => this.reportPage()
          window.addEventListener("phx:page-loading-stop", this.onNavigate)
        },

        updated() { this.schedule() },

        // After the socket reconnects or this LiveView rejoins, the server
        // has mounted again without a page; the path hasn't changed, so the
        // check in reportPage() would keep it quiet. Report it again.
        reconnected() {
          this.path = null
          this.reportPage()
        },

        destroyed() {
          document.removeEventListener("keydown", this.onKey)
          document.removeEventListener("pointerdown", this.onOutside, true)
          window.removeEventListener("phx:page-loading-stop", this.onNavigate)
          for (const timer of this.timers.values()) clearTimeout(timer.handle)
        },

        panel() { return this.state },

        act(action) {
          const now = this.panel()
          if (action === "close") this.go("closed")
          if (action === "open") this.go("open")
          if (action === "pin") this.go(now === "pinned" ? "open" : "pinned")
          if (action === "full") this.go(now === "full" ? "open" : "full")
        },

        go(to, {refocus = true} = {}) {
          const from = this.state
          if (from === to) return
          this.state = to
          this.pushEvent("panel", {to})
          // Applies whatever the state is by then, in case it changed again.
          const apply = () => {
            const now = this.state
            this.js().setAttribute(this.el, "data-panel", now)
            this.mark(now)
          }
          // With reduced motion, app.css keeps the transition to a fade. A
          // transition waits for the page to draw a frame, and while it runs
          // it takes every click; a page that isn't drawing (a covered
          // window) would hang there, so one that runs long is skipped.
          let done = Promise.resolve()
          if (document.startViewTransition) {
            const transition = document.startViewTransition(apply)
            const guard = setTimeout(() => transition.skipTransition(), 1000)
            done = transition.finished.finally(() => clearTimeout(guard))
          } else {
            apply()
          }
          done.finally(() => {
            if (this.state !== to || !refocus) return
            if (to === "closed") this.el.querySelector("#blip-face")?.focus()
            else if (from === "closed") this.el.querySelector("#composer-input")?.focus()
          })
        },

        // Pages make room for a pinned panel from this (see app.css).
        mark(panel) { document.documentElement.dataset.blipPanel = panel },

        // Each path once: a navigation that stays on the page says nothing.
        reportPage() {
          if (location.pathname === this.path) return
          this.path = location.pathname
          this.pushEvent("page", {path: this.path})
        },

        // A timer for each bubble on screen, from when it first shows.
        schedule() {
          const shown = new Set()
          for (const el of this.el.querySelectorAll("[data-bubble]:not(.is-leaving)")) {
            const id = el.dataset.bubble
            shown.add(id)
            if (this.timers.has(id)) continue
            const words = el.textContent.trim().split(/\s+/).length
            const left = Math.min(READ_MAX_MS, Math.max(READ_MIN_MS, 3000 + words * MS_PER_WORD))
            this.timers.set(id, {left})
            if (!this.held) this.run(id)
          }
          for (const [id, timer] of this.timers) {
            if (shown.has(id)) continue
            clearTimeout(timer.handle)
            this.timers.delete(id)
          }
        },

        run(id) {
          const timer = this.timers.get(id)
          timer.since = performance.now()
          timer.handle = setTimeout(() => this.dismiss(id), timer.left)
        },

        hold() {
          if (this.held) return
          this.held = true
          for (const timer of this.timers.values()) {
            clearTimeout(timer.handle)
            timer.left -= performance.now() - timer.since
          }
        },

        // Looking away gives at least a moment more before a bubble goes.
        release() {
          if (!this.held) return
          this.held = false
          for (const [id, timer] of this.timers) {
            timer.left = Math.max(timer.left, AGAIN_MS)
            this.run(id)
          }
        },

        dismiss(id) {
          clearTimeout(this.timers.get(id)?.handle)
          this.timers.delete(id)
          this.pushEvent("dismiss_bubble", {id})
        },

        dismissAll() {
          for (const timer of this.timers.values()) clearTimeout(timer.handle)
          this.timers.clear()
          this.pushEvent("dismiss_bubbles", {})
        }
      }
    </script>
    """
  end

  # Where an image in Blip's conversation loads from.
  defp image_path(entry_id, index), do: ~p"/blip/images/#{entry_id}/#{index}"

  # The line under Blip's name in the panel header.
  defp status_line(_mood, %{model_ready: false}), do: "Needs a ChatGPT sign-in"
  defp status_line(:thinking, _shell), do: "Thinking"
  defp status_line(:done, _shell), do: "Done"
  defp status_line(:error, _shell), do: "Something failed"
  defp status_line(_mood, %{model: model}), do: "On #{model}"

  attr :page, :map, required: true

  # The page the next message goes with, inside the message box, with a ×
  # to leave it out.
  defp page_chip(assigns) do
    ~H"""
    <span
      id="page-chip"
      class="flex max-w-full items-center gap-1.5 rounded-lg bg-accent-soft py-1 pr-1 pl-2 text-[12px] text-ink-soft"
      title="Blip sees this page with your message"
    >
      <.icon name="hero-eye-micro" class="size-3.5 shrink-0 text-accent-strong" />
      <span class="min-w-0 truncate">About {@page["label"]}</span>
      <button
        type="button"
        id="page-chip-dismiss"
        phx-click="dismiss_page"
        class="shrink-0 rounded p-0.5 text-ink-faint transition hover:bg-surface/70 hover:text-ink"
        title="Don't include this page"
        aria-label="Don't include this page"
      >
        <.icon name="hero-x-mark-micro" class="size-3.5" />
      </button>
    </span>
    """
  end

  attr :reply, :map, required: true
  attr :titles, :map, required: true

  # The question the next message answers, inside the message box, with a
  # × to go back to talking to Blip.
  defp reply_chip(assigns) do
    ~H"""
    <span
      id="reply-chip"
      class="flex max-w-full items-center gap-1.5 rounded-lg bg-warn-soft py-1 pr-1 pl-2 text-[12px] text-ink-soft ring-1 ring-warn/30"
      title="What you send goes straight to the thread"
    >
      <.icon name="hero-arrow-uturn-left-micro" class="size-3.5 shrink-0 text-warn" />
      <span class="min-w-0 truncate">
        Answering
        <span class="font-medium text-ink">
          {Transcript.title(@titles, @reply.thread_id, @reply.title) || "a thread"}
        </span>
      </span>
      <button
        type="button"
        id="reply-chip-dismiss"
        phx-click="dismiss_reply"
        class="shrink-0 rounded p-0.5 text-ink-faint transition hover:bg-surface/70 hover:text-ink"
        title="Don't answer the question"
        aria-label="Don't answer the question"
      >
        <.icon name="hero-x-mark-micro" class="size-3.5" />
      </button>
    </span>
    """
  end

  attr :bubble, :map, required: true
  attr :titles, :map, required: true

  # Blip saying something, in a speech bubble above it: the whole first
  # paragraph. Clicking it opens the chat. The × dismisses it. The tail
  # points down at Blip.
  defp bubble(assigns) do
    ~H"""
    <div
      id={"bubble-#{@bubble.id}"}
      data-bubble={@bubble.id}
      class={[
        "blip-bubble",
        @bubble.leaving && "is-leaving",
        @bubble.kind == :error && "is-failed",
        @bubble.kind == :question && "is-question"
      ]}
    >
      <div class="blip-bubble-clip">
        <div class="blip-bubble-card" data-blip-action="open">
          <div class="markdown-body blip-bubble-text">
            {raw(Markdown.to_html(Notice.text(@bubble, @titles)))}
          </div>
          <button
            type="button"
            class="blip-bubble-close"
            data-bubble-dismiss={@bubble.id}
            aria-label="Dismiss"
            title="Dismiss (Esc)"
          >
            <.icon name="hero-x-mark-micro" class="size-4" />
          </button>
        </div>
        <span class="blip-bubble-tail" aria-hidden="true" />
      </div>
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
        I'm a photon living on this hub. I run commands on your machines and tell you what actually happened.
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
end
