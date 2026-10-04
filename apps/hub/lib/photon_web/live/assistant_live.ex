defmodule PhotonWeb.AssistantLive do
  @moduledoc """
  The conversation with Blip, the assistant. Everything shown is committed
  state from `Photon.Assistant`, plus the in-flight model output
  (`{:live, ...}` events), which is shown until the finished response is
  committed. What is shown, how live events fold into the in-flight answer,
  and Blip's mood are `Photon.Assistant.Transcript`.

  Blip's mood comes from what is happening now, except for an outcome (a
  finish or a failure), which the page holds for a moment so it can be
  seen: `@outcome`, cleared by a `{:blip_rest, ref}` timer.
  """

  use PhotonWeb, :live_view

  alias Photon.{Assistant, Markdown}
  alias Photon.Assistant.Transcript
  alias PhotonCore.Message

  # How long Blip shows an outcome before going back to what's happening.
  @hold_ms %{done: 2_200, error: 4_000}

  @impl true
  def mount(_params, _session, socket) do
    conversation = Assistant.conversation_id()
    if connected?(socket), do: Assistant.subscribe(conversation)

    entries = Assistant.entries(conversation)
    %{results: results, calls: calls, settled: settled} = Transcript.index(entries)

    {:ok,
     socket
     |> assign(
       page_title: "Blip",
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
       memory: Assistant.memory(),
       editing_memory: false,
       schedules: Assistant.schedules(),
       form: to_form(%{"text" => ""}, as: :message)
     )
     |> stream(:entries, Enum.filter(entries, &Transcript.shown?/1))}
  end

  ## Events

  @impl true
  def handle_event("send", %{"message" => %{"text" => text}}, socket) do
    case String.trim(text) do
      "" ->
        {:noreply, socket}

      text ->
        {:ok, _} = Assistant.send(text, when_busy: socket.assigns.mode)

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

  def handle_event("fresh_start", _params, socket) do
    Assistant.fresh_start(socket.assigns.conversation)

    {:noreply,
     put_flash(
       socket,
       :info,
       "Started a fresh context. Earlier messages stay here, but Blip won't see them."
     )}
  end

  def handle_event("edit_memory", _params, socket),
    do: {:noreply, assign(socket, editing_memory: true)}

  def handle_event("cancel_memory", _params, socket),
    do: {:noreply, assign(socket, editing_memory: false)}

  def handle_event("save_memory", %{"memory" => text}, socket) do
    Assistant.put_memory(text)
    {:noreply, assign(socket, memory: Assistant.memory(), editing_memory: false)}
  end

  def handle_event("cancel_schedule", %{"id" => id}, socket) do
    Assistant.cancel_schedule(id)
    {:noreply, socket}
  end

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

    {:noreply, socket}
  end

  def handle_info({:durable, "global", changes}, socket) do
    if Enum.any?(changes.docs, &(&1.kind == "memory")),
      do: {:noreply, assign(socket, memory: Assistant.memory())},
      else: {:noreply, socket}
  end

  def handle_info({:durable_tasks, tasks}, socket) do
    if Enum.any?(tasks, &(&1.kind == "routine")),
      do: {:noreply, assign(socket, schedules: Assistant.schedules())},
      else: {:noreply, socket}
  end

  def handle_info(
        {:live, conversation, event},
        %{assigns: %{conversation: conversation}} = socket
      ) do
    {:noreply, assign(socket, live: Transcript.live(socket.assigns.live, event))}
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
      assign(
        assigns,
        :mood,
        Transcript.mood(%{
          outcome: assigns.outcome,
          live: assigns.live,
          working: length(assigns.shell.working),
          busy: assigns.busy
        })
      )

    ~H"""
    <Layouts.app flash={@flash} shell={@shell} active={:assistant} mood={@mood}>
      <div class="flex h-full">
        <section class="flex min-w-0 flex-1 flex-col">
          <div
            id="conversation"
            phx-hook=".StickToBottom"
            class="min-h-0 flex-1 overflow-y-auto"
          >
            <div class="mx-auto w-full max-w-3xl px-4 pt-8 pb-6 sm:px-6">
              <.empty_state :if={@empty?} shell={@shell} mood={@mood} />

              <div id="entries" phx-update="stream" class="space-y-6">
                <div :for={{dom_id, entry} <- @streams.entries} id={dom_id} class="animate-rise">
                  <.entry entry={entry} results={@results} settled={@settled} />
                </div>
              </div>

              <.live_output
                :if={@live || @mood != :idle}
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
          />
          <.sign_in_to_talk :if={!@shell.model_ready} chatgpt={@shell.chatgpt} />
        </section>

        <.rail
          shell={@shell}
          schedules={@schedules}
          memory={@memory}
          editing_memory={@editing_memory}
        />
      </div>
    </Layouts.app>

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

  attr :shell, :map, required: true
  attr :mood, :atom, required: true

  defp empty_state(assigns) do
    online = Enum.filter(assigns.shell.nodes, & &1.online)
    assigns = assign(assigns, online: online, first: List.first(online))

    ~H"""
    <div id="empty-state" class="pt-[8vh] pb-10 text-center">
      <.blip
        id="blip-hello"
        state={@mood}
        size={112}
        contained={false}
        interactive
        label="Blip, a small amber dot with two tall oval eyes"
        class="mx-auto mb-5"
      />
      <h1 class="text-2xl font-semibold tracking-tight">Hi. I'm Blip.</h1>
      <p class="mx-auto mt-2 max-w-md text-[15px] leading-relaxed text-ink-soft">
        I'm a photon living on this hub. I can't run commands myself, so I hand work to your machines and tell you what they actually did.
      </p>
      <p :if={!@shell.model_ready} class="mx-auto mt-4 max-w-md text-sm text-ink-soft">
        First I need a model to think with. Sign in with ChatGPT and I'll use your plan.
      </p>
      <p
        :if={@shell.model_ready and @online == []}
        class="mx-auto mt-4 max-w-md text-sm text-ink-faint"
      >
        No machines yet, so I have nowhere to send work.
        <.link navigate={~p"/nodes"} class="text-accent-strong underline underline-offset-2">Add one</.link>
        first.
      </p>
      <div
        :if={@shell.model_ready}
        class="mx-auto mt-7 flex max-w-xl flex-wrap justify-center gap-2"
      >
        <button
          :for={example <- examples(@first && @first.id)}
          phx-click="example"
          phx-value-text={example}
          class="rounded-full border border-line bg-surface px-3.5 py-1.5 text-[13px] text-ink-soft shadow-xs transition hover:-translate-y-px hover:border-accent/40 hover:text-ink"
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
    assigns =
      assign(assigns,
        source: assigns.entry.data["source"] || %{},
        text: Message.text_of(assigns.entry.data["message"])
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
        <div class="flex justify-end pl-12">
          <div class="max-w-full rounded-2xl rounded-br-md bg-sunken px-4 py-2.5 text-[15px] leading-relaxed text-ink ring-1 ring-line">
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
    <div class="flex gap-3">
      <.avatar id={"blip-#{@entry.id}"} still />
      <div class="min-w-0 flex-1 space-y-2.5 pt-0.5">
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
    </div>
    """
  end

  defp entry(%{entry: %{kind: "error"}} = assigns) do
    assigns = assign(assigns, quiet: Transcript.quiet?(assigns.entry.data))

    ~H"""
    <div class={[
      "ml-10 flex items-start gap-2 rounded-xl px-3.5 py-2.5 text-sm",
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

  attr :id, :string, required: true
  attr :state, :atom, default: :idle
  attr :still, :boolean, default: false
  attr :interactive, :boolean, default: false

  defp avatar(assigns) do
    ~H"""
    <span class="mt-0.5 grid size-7 shrink-0 place-items-center">
      <.blip id={@id} state={@state} size={32} still={@still} interactive={@interactive} />
    </span>
    """
  end

  attr :source, :map, required: true
  attr :text, :string, required: true

  defp report(assigns) do
    body = assigns.text |> String.split("\n", parts: 2) |> Enum.at(1, "") |> String.trim()
    assigns = assign(assigns, body: body)

    ~H"""
    <div class="ml-10 overflow-hidden rounded-xl border border-line bg-surface shadow-xs">
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

  # Blip, live: the in-flight answer, or what Blip is up to between answers
  # (waiting on a run, node work still going, or an outcome it is showing).
  defp live_output(%{live: nil} = assigns) do
    ~H"""
    <div id="live-output" class="mt-6 flex gap-3">
      <%!-- Watched while it works, Blip gets a little flustered (hover). --%>
      <.avatar id="blip-live" state={@mood} interactive />
      <div class="min-w-0 flex-1">
        <div :if={@mood == :thinking} class="flex h-8 items-center">
          <.thinking />
        </div>
        <div :if={@mood == :working} class="space-y-1 pt-1.5">
          <p
            :for={s <- @working}
            id={"live-work-#{s.id}"}
            class="flex items-center gap-2 text-[13px] text-ink-soft"
          >
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
    </div>
    """
  end

  defp live_output(assigns) do
    ~H"""
    <div id="live-output" class="mt-6 flex gap-3">
      <%!-- Watched while it works, Blip gets a little flustered (hover). --%>
      <.avatar id="blip-live" state={@mood} interactive />
      <div class="min-w-0 flex-1 space-y-2 pt-0.5">
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
          class="-mt-0.5 flex h-8 items-center"
        >
          <.thinking />
        </div>
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
    <div class="shrink-0 border-t border-line bg-canvas/90 px-4 pt-3 pb-4 backdrop-blur sm:px-6">
      <div
        id="sign-in-to-talk"
        class="mx-auto flex w-full max-w-3xl flex-wrap items-center justify-between gap-3 rounded-2xl border border-line bg-surface px-4 py-3 shadow-sm"
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

  defp composer(assigns) do
    ~H"""
    <div class="shrink-0 border-t border-line bg-canvas/90 px-4 pt-3 pb-4 backdrop-blur sm:px-6">
      <div class="mx-auto w-full max-w-3xl">
        <div :if={@queued != []} id="queued" class="mb-2 flex flex-wrap gap-1.5">
          <span
            :for={s <- @queued}
            id={"queued-#{s.id}"}
            class="flex max-w-full items-center gap-1.5 rounded-full border border-line bg-surface py-1 pr-1 pl-3 text-[12px] text-ink-soft"
          >
            <span class="font-medium text-ink-faint">{if(s.mode == "steer", do: "Steer", else: "Next")}</span>
            <span class="max-w-72 truncate">{Message.text_of(s.content["parts"])}</span>
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
          class="rounded-2xl border border-line bg-surface shadow-sm transition focus-within:border-accent/60 focus-within:shadow-md focus-within:shadow-accent/10"
        >
          <textarea
            id="composer-input"
            name={@form[:text].name}
            phx-hook=".Composer"
            rows="1"
            placeholder={if(@busy, do: "Add to the conversation...", else: "Ask Blip anything...")}
            class="block max-h-60 min-h-12 w-full resize-none bg-transparent px-4 pt-3 pb-1 text-[15px] leading-relaxed text-ink outline-none placeholder:text-ink-faint"
          >{@form[:text].value}</textarea>
          <div class="flex items-center gap-2 px-2.5 pb-2.5">
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
            <span class="hidden text-[11px] text-ink-faint sm:inline">Enter to send · Shift+Enter for a new line</span>
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

  attr :shell, :map, required: true
  attr :schedules, :list, required: true
  attr :memory, :string, required: true
  attr :editing_memory, :boolean, required: true

  defp rail(assigns) do
    working =
      Enum.filter(
        assigns.shell.sessions,
        &(&1.origin == "assistant" and &1.status in ["running", "pending"])
      )

    assigns = assign(assigns, working: working)

    ~H"""
    <aside class="hidden w-80 shrink-0 overflow-y-auto border-l border-line bg-surface/60 px-5 py-6 xl:block">
      <section>
        <h2 class="text-[11px] font-semibold tracking-wider text-ink-faint uppercase">In progress</h2>
        <p :if={@working == []} class="mt-2 text-[13px] text-ink-faint">
          Nothing running on your machines.
        </p>
        <.link
          :for={s <- @working}
          navigate={~p"/sessions/#{s.id}"}
          class="mt-2 flex items-center gap-2.5 rounded-lg border border-line bg-surface px-3 py-2 text-[13px] transition hover:border-accent/40"
        >
          <span class="text-accent-strong"><.spinner class="size-3.5" /></span>
          <span class="min-w-0 flex-1">
            <span class="block truncate text-ink">{s.title}</span>
            <span class="text-[11px] text-ink-faint">{s.node_id}</span>
          </span>
        </.link>
      </section>

      <section class="mt-7">
        <h2 class="text-[11px] font-semibold tracking-wider text-ink-faint uppercase">Schedules</h2>
        <p :if={@schedules == []} class="mt-2 text-[13px] leading-relaxed text-ink-faint">
          None yet. Ask for something recurring, like "every morning, check my disks".
        </p>
        <div
          :for={task <- @schedules}
          id={"schedule-#{task.id}"}
          class="group mt-2 rounded-lg border border-line bg-surface px-3 py-2 text-[13px]"
        >
          <div class="flex items-start gap-2">
            <.icon name="hero-clock" class="mt-0.5 size-4 shrink-0 text-ink-faint" />
            <p class="min-w-0 flex-1 leading-snug text-ink">{task.input["prompt"]}</p>
            <button
              phx-click="cancel_schedule"
              phx-value-id={task.id}
              data-confirm="Cancel this schedule?"
              class="rounded p-0.5 text-ink-faint opacity-0 transition group-hover:opacity-100 hover:text-bad"
              title="Cancel"
            >
              <.icon name="hero-x-mark-micro" class="size-4" />
            </button>
          </div>
          <p class="mt-1 pl-6 text-[11px] text-ink-faint">{schedule_text(task)}</p>
        </div>
      </section>

      <section class="mt-7">
        <div class="flex items-center justify-between">
          <h2 class="text-[11px] font-semibold tracking-wider text-ink-faint uppercase">Memory</h2>
          <button
            :if={!@editing_memory}
            phx-click="edit_memory"
            class="text-[12px] text-ink-faint hover:text-ink"
          >Edit</button>
        </div>
        <form :if={@editing_memory} id="memory-form" phx-submit="save_memory" class="mt-2 space-y-2">
          <textarea
            name="memory"
            rows="8"
            class={[field_class(), "h-auto py-2 font-mono text-[12px] leading-relaxed"]}
          >{@memory}</textarea>
          <div class="flex justify-end gap-2">
            <.button type="button" size="sm" variant="ghost" phx-click="cancel_memory">Cancel</.button>
            <.button type="submit" size="sm" variant="primary">Save</.button>
          </div>
        </form>
        <div
          :if={!@editing_memory}
          class="mt-2 rounded-lg bg-sunken px-3 py-2.5 text-[12.5px] leading-relaxed text-ink-soft"
        >
          <span phx-no-format class="whitespace-pre-wrap">{if(@memory == "", do: "Empty. Blip saves facts here as it learns them.", else: @memory)}</span>
        </div>
      </section>

      <section class="mt-7 border-t border-line pt-5">
        <button
          phx-click="fresh_start"
          data-confirm="Start a fresh context? Blip stops seeing earlier messages (they stay here). Memory is kept."
          class="flex items-center gap-2 text-[12.5px] text-ink-faint transition hover:text-ink"
        >
          <.icon name="hero-arrow-path" class="size-4" /> Start a fresh context
        </button>
      </section>
    </aside>
    """
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
