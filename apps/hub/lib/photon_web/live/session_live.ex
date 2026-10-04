defmodule PhotonWeb.SessionLive do
  @moduledoc """
  One node session: everything the node's agent did, with command output
  streaming in while it runs. The user can message the session directly or
  stop it.

  The page folds the session's records with `Photon.NodeTranscript` and
  streams the items that change. Live model text and command output are
  shown until the record that replaces them arrives.
  """

  use PhotonWeb, :live_view

  alias Photon.{Markdown, Nodes, NodeSessions, NodeTranscript}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case NodeSessions.get(id) do
      nil ->
        {:ok,
         socket |> put_flash(:error, "That session doesn't exist.") |> push_navigate(to: ~p"/")}

      session ->
        if connected?(socket), do: NodeSessions.subscribe(id)
        transcript = NodeTranscript.build(NodeSessions.events(id))

        {:ok,
         socket
         |> assign(
           page_title: session.title,
           session: session,
           online?: Nodes.online?(session.node_id),
           transcript: transcript,
           live_text: "",
           live_shown: "",
           live_output: %{},
           form: to_form(%{"text" => ""}, as: :message)
         )
         |> stream(:items, NodeTranscript.items(transcript))}
    end
  end

  @impl true
  def handle_event("send", %{"message" => %{"text" => text}}, socket) do
    case String.trim(text) do
      "" ->
        {:noreply, socket}

      text ->
        {:ok, _} = NodeSessions.send_input(socket.assigns.session.id, text)
        {:noreply, assign(socket, form: to_form(%{"text" => ""}, as: :message))}
    end
  end

  def handle_event("stop", _params, socket) do
    session = socket.assigns.session
    stopped = NodeSessions.stop(session.id)
    {:noreply, stop_flash(socket, stopped, Nodes.online?(session.node_id))}
  end

  def handle_event("delete", _params, socket) do
    NodeSessions.delete(socket.assigns.session.id)
    {:noreply, socket |> put_flash(:info, "Deleted the session.") |> push_navigate(to: ~p"/")}
  end

  # A stop is queued like a message; say so when the node won't get it yet.
  defp stop_flash(socket, nil, _online),
    do: put_flash(socket, :error, "This session no longer exists.")

  defp stop_flash(socket, {:ok, _stop}, true = _online), do: socket

  defp stop_flash(socket, {:ok, _stop}, false = _online) do
    node = socket.assigns.session.node_id
    put_flash(socket, :info, "#{node} is offline. It stops this session when it reconnects.")
  end

  @impl true
  def handle_info({:node_event, id, record}, %{assigns: %{session: %{id: id}}} = socket) do
    {transcript, changed} = NodeTranscript.fold(socket.assigns.transcript, record)

    socket =
      Enum.reduce(changed, assign(socket, transcript: transcript), fn item, socket ->
        socket
        |> stream_insert(:items, item)
        |> clear_live(item)
      end)

    {:noreply, socket}
  end

  def handle_info({:node_live, id, data}, %{assigns: %{session: %{id: id}}} = socket),
    do: {:noreply, add_live(socket, data)}

  def handle_info(:node_sessions_changed, socket) do
    case NodeSessions.get(socket.assigns.session.id) do
      nil -> {:noreply, socket}
      session -> {:noreply, assign(socket, session: session)}
    end
  end

  def handle_info(:nodes_changed, socket),
    do: {:noreply, assign(socket, online?: Nodes.online?(socket.assigns.session.node_id))}

  def handle_info(_message, socket), do: {:noreply, socket}

  # The agent's text is shown a finished block at a time, and its Markdown
  # rendered again only when one is added; command output as it comes.
  defp add_live(socket, %{"type" => "text", "delta" => delta}) do
    text = socket.assigns.live_text <> delta
    assign(socket, live_text: text, live_shown: Markdown.settled(text))
  end

  defp add_live(socket, %{"type" => "op_output", "op" => op, "text" => text}) do
    update(socket, :live_output, fn outputs ->
      Map.update(outputs, op, text, &tail(&1 <> text))
    end)
  end

  defp add_live(socket, _data), do: socket

  defp clear_live(socket, %{type: :assistant}), do: assign(socket, live_text: "", live_shown: "")

  defp clear_live(socket, %{type: :tool, op: op, status: status}) when status != :running,
    do: update(socket, :live_output, &Map.delete(&1, op))

  defp clear_live(socket, _item), do: socket

  defp tail(text) when byte_size(text) > 20_000,
    do: binary_part(text, byte_size(text) - 20_000, 20_000)

  defp tail(text), do: text

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} shell={@shell} socket={@socket} active={{:session, @session.id}}>
      <div class="flex h-full flex-col">
        <header class="shrink-0 border-b border-line bg-surface/70 px-4 py-3 backdrop-blur sm:px-6">
          <div class="mx-auto flex w-full max-w-3xl items-center gap-3">
            <div class="min-w-0 flex-1">
              <div class="flex items-center gap-2 text-[12px] text-ink-faint">
                <.dot status={if(@online?, do: :ok, else: :off)} />
                <span class="font-medium text-ink-soft">{@session.node_id}</span>
                <span>·</span>
                <span>{if(@session.origin == "assistant",
                  do: "started by the assistant",
                  else: "started by you"
                )}</span>
              </div>
              <h1
                class="mt-0.5 truncate text-[17px] font-semibold tracking-tight"
                title={@session.title}
              >
                {@session.title}
              </h1>
            </div>
            <.status_pill status={@session.status} />
            <.button :if={@session.status == "running"} id="stop-session" size="sm" phx-click="stop">
              <.icon name="hero-stop-solid" class="size-3.5" /> Stop
            </.button>
            <.button
              id="delete-session"
              size="sm"
              variant="ghost"
              phx-click="delete"
              data-confirm="Delete this session here and on the node?"
              title="Delete"
            >
              <.icon name="hero-trash" class="size-4" />
            </.button>
          </div>
        </header>

        <div id="session-scroll" phx-hook="PinToBottom" class="min-h-0 flex-1 overflow-y-auto">
          <div class="mx-auto w-full max-w-3xl px-4 py-6 sm:px-6">
            <div id="items" phx-update="stream" class="space-y-4">
              <%!-- An answer arrives already shown, streamed in: no rise. --%>
              <div
                :for={{dom_id, item} <- @streams.items}
                id={dom_id}
                class={item.type != :assistant && "animate-rise"}
              >
                <.item item={item} />
              </div>
            </div>

            <div :for={{op, text} <- @live_output} id={"live-#{op}"} class="mt-4 ml-10">
              <pre class="max-h-64 overflow-auto rounded-xl bg-sunken px-3.5 py-2.5 font-mono text-[12px] leading-relaxed whitespace-pre-wrap text-ink-soft">{text}</pre>
            </div>

            <div :if={@live_shown != ""} class="mt-4 flex gap-3">
              <.agent_mark />
              <div id="live-text" class="markdown-body min-w-0 flex-1 text-ink" data-streaming>
                {raw(Markdown.to_html(@live_shown))}
              </div>
            </div>

            <p
              :if={@session.status == "pending"}
              class="mt-6 flex items-center gap-2 text-sm text-ink-faint"
            >
              <.spinner /> {if(@online?,
                do: "Handing the task to #{@session.node_id}...",
                else: "#{@session.node_id} is offline. The task will start when it reconnects."
              )}
            </p>
          </div>
          <.jump_to_latest />
        </div>

        <%!-- Room on the right for Blip, in the corner, until the page is wide enough. --%>
        <div class="blip-clear-x shrink-0 border-t border-line bg-canvas/90 px-4 pt-3 pb-4 backdrop-blur sm:px-6">
          <.form
            for={@form}
            id="session-composer"
            phx-submit="send"
            class="mx-auto flex w-full max-w-3xl items-end gap-2"
          >
            <textarea
              id="session-input"
              name={@form[:text].name}
              rows="1"
              phx-hook=".SubmitOnEnter"
              placeholder={"Message the agent on #{@session.node_id}..."}
              class="block max-h-48 min-h-10 flex-1 resize-none rounded-xl border border-line bg-surface px-3.5 py-2.5 text-[14px] leading-relaxed text-ink shadow-xs outline-none transition placeholder:text-ink-faint focus:border-accent/60"
            >{@form[:text].value}</textarea>
            <.button type="submit" variant="primary" class="h-10 rounded-xl" disabled={!@online?}>Send</.button>
          </.form>
        </div>
      </div>
    </Layouts.app>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".SubmitOnEnter">
      export default {
        mounted() {
          this.el.addEventListener("keydown", e => {
            if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
              e.preventDefault()
              if (this.el.value.trim() !== "") this.el.form.requestSubmit()
            }
          })
          this.el.form.addEventListener("submit", () => setTimeout(() => { this.el.value = "" }, 0))
        }
      }
    </script>
    """
  end

  attr :status, :string, required: true

  @spec status_pill(map()) :: Phoenix.LiveView.Rendered.t()
  def status_pill(assigns) do
    ~H"""
    <span class={[
      "inline-flex shrink-0 items-center gap-1.5 rounded-full px-2.5 py-1 text-[12px] font-medium",
      @status == "running" && "bg-accent-soft text-accent-strong",
      @status == "idle" && "bg-ok-soft text-ok",
      @status == "pending" && "bg-sunken text-ink-soft",
      @status in ["stopped", "failed"] && "bg-bad-soft text-bad"
    ]}>
      <.dot :if={@status == "running"} status={:busy} />
      {status_text(@status)}
    </span>
    """
  end

  defp status_text("running"), do: "Working"
  defp status_text("idle"), do: "Done"
  defp status_text("pending"), do: "Waiting"
  defp status_text("stopped"), do: "Stopped"
  defp status_text("failed"), do: "Failed"
  defp status_text(other), do: other

  defp agent_mark(assigns) do
    ~H"""
    <span class="mt-0.5 grid size-7 shrink-0 place-items-center rounded-lg bg-sunken text-ink-soft ring-1 ring-line">
      <.icon name="hero-cpu-chip" class="size-4" />
    </span>
    """
  end

  attr :item, :map, required: true

  defp item(%{item: %{type: :user}} = assigns) do
    ~H"""
    <div class="flex justify-end pl-12">
      <div class="max-w-full rounded-2xl rounded-br-md bg-sunken px-4 py-2.5 text-[14px] leading-relaxed text-ink ring-1 ring-line">
        <span phx-no-format class="whitespace-pre-wrap">{@item.text}</span>
        <span :if={@item.images > 0} class="mt-1 block text-[12px] text-ink-faint">{@item.images} image(s)</span>
      </div>
    </div>
    """
  end

  defp item(%{item: %{type: :assistant}} = assigns) do
    ~H"""
    <div class="flex gap-3">
      <.agent_mark />
      <div class="min-w-0 flex-1 space-y-2 pt-0.5">
        <details :if={@item.reasoning not in [nil, ""]} class="group text-[13px] text-ink-faint">
          <summary class="cursor-pointer list-none select-none hover:text-ink-soft">
            <.icon name="hero-light-bulb-micro" class="size-3.5" /> Reasoning
          </summary>
          <p class="mt-1.5 border-l-2 border-line pl-3 leading-relaxed">
            <span phx-no-format class="whitespace-pre-wrap">{@item.reasoning}</span>
          </p>
        </details>
        <div :if={@item.text != ""} class="markdown-body text-ink">
          {raw(Markdown.to_html(@item.text))}
        </div>
      </div>
    </div>
    """
  end

  defp item(%{item: %{type: :tool}} = assigns) do
    ~H"""
    <div class="ml-10 overflow-hidden rounded-xl border border-line bg-surface shadow-xs">
      <div class="flex items-center gap-2.5 px-3 py-2 text-[13px]">
        <span class={[
          "grid size-6 shrink-0 place-items-center rounded-md",
          @item.status in [:pending, :running] && "bg-accent-soft text-accent-strong",
          @item.status == :done && (exit_ok?(@item) && "bg-ok-soft text-ok"),
          @item.status == :done && (!exit_ok?(@item) && "bg-warn-soft text-warn"),
          @item.status in [:error, :canceled] && "bg-bad-soft text-bad"
        ]}>
          <.spinner :if={@item.status in [:pending, :running]} class="size-3.5" />
          <.icon :if={@item.status == :done} name={tool_icon(@item.name)} class="size-3.5" />
          <.icon :if={@item.status in [:error, :canceled]} name="hero-x-mark-micro" class="size-3.5" />
        </span>
        <code
          class="min-w-0 flex-1 truncate font-mono text-[12.5px] text-ink"
          title={tool_label(@item)}
        >{tool_label(@item)}</code>
        <span
          :if={@item[:exit_code] not in [nil, 0]}
          class="shrink-0 rounded bg-warn-soft px-1.5 py-0.5 font-mono text-[11px] text-warn"
        >
          exit {@item.exit_code}
        </span>
        <span :if={@item.status == :canceled} class="shrink-0 text-[11px] text-bad">canceled</span>
      </div>
      <img
        :if={@item[:image]}
        src={"data:#{@item.image.mime};base64,#{@item.image.data}"}
        class="max-h-96 w-full border-t border-line bg-sunken object-contain"
        alt={@item[:output] || "Image"}
      />
      <pre
        :if={tool_output(@item) != ""}
        class="max-h-80 overflow-auto border-t border-line bg-sunken/60 px-3.5 py-2.5 font-mono text-[12px] leading-relaxed whitespace-pre-wrap text-ink-soft"
      >{tool_output(@item)}</pre>
    </div>
    """
  end

  defp item(%{item: %{type: :notice}} = assigns) do
    ~H"""
    <div class={[
      "ml-10 flex items-center gap-2 text-[12.5px]",
      @item.kind == :failure && "rounded-lg bg-bad-soft px-3 py-2 text-ink",
      @item.kind != :failure && "text-ink-faint"
    ]}>
      <.icon name={notice_icon(@item.kind)} class={["size-4", @item.kind == :failure && "text-bad"]} />
      {@item.text}
    </div>
    """
  end

  defp exit_ok?(item), do: item[:exit_code] in [nil, 0]

  defp tool_label(%{name: "Bash", args: %{"command" => command}}), do: "$ " <> command
  defp tool_label(%{name: "ViewImage", args: %{"path" => path}}), do: "view " <> path
  defp tool_label(%{name: "SkillUse", args: %{"name" => name}}), do: "skill " <> name
  defp tool_label(%{name: name, args: args}), do: "#{name} #{Jason.encode!(args)}"

  defp tool_icon("Bash"), do: "hero-command-line-micro"
  defp tool_icon("ViewImage"), do: "hero-photo-micro"
  defp tool_icon(_), do: "hero-book-open-micro"

  defp tool_output(%{status: status}) when status in [:pending, :running], do: ""

  defp tool_output(item) do
    text =
      [item[:output], item[:stderr] not in [nil, ""] && "stderr:\n" <> item.stderr, item[:error]]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.join("\n\n")
      |> String.trim_trailing()

    if text == "" and item.status == :done and !item[:image], do: "(no output)", else: text
  end

  defp notice_icon(:heartbeat), do: "hero-heart-micro"
  defp notice_icon(:stop), do: "hero-stop-circle-micro"
  defp notice_icon(:settings), do: "hero-adjustments-horizontal-micro"
  defp notice_icon(_), do: "hero-exclamation-triangle-micro"
end
