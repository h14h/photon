defmodule PhotonWeb.PlaygroundLive do
  use PhotonWeb, :live_view

  alias Photon.{Attachments, Nodes, Sessions, Settings, Transcript}
  import PhotonWeb.TranscriptComponents

  # Raw events kept in memory for the inspector tab.
  @raw_limit 500

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Photon.PubSub, Sessions.topic())
      Phoenix.PubSub.subscribe(Photon.PubSub, Nodes.topic())
      Phoenix.PubSub.subscribe(Photon.PubSub, Settings.topic())
      Phoenix.PubSub.subscribe(Photon.PubSub, Photon.Provision.topic())
    end

    {:ok,
     socket
     |> assign(
       settings: Settings.load(),
       sessions: Sessions.list(),
       session: nil,
       server_uri: nil,
       show_connect: false,
       tailnet: nil,
       jobs: Photon.Provision.jobs(),
       ssh_user: "",
       transcript: Transcript.new(),
       raw: [],
       running: false,
       tab: :chat,
       show_control: false,
       show_settings: true
     )
     |> allow_upload(:images,
       accept: Attachments.exts(),
       max_entries: 4,
       max_file_size: 10_000_000,
       auto_upload: true
     )
     |> assign_nodes()}
  end

  # Node state is derived from the registry on every change, which keeps the
  # running indicators honest when a node drops mid-run.
  defp assign_nodes(socket) do
    nodes = Nodes.list()
    running_ids = Enum.reduce(nodes, MapSet.new(), &MapSet.union(&2, &1["running"]))
    latest = Photon.NodeDist.version()

    outdated =
      for n <- nodes, Photon.NodeDist.outdated?(n, latest), into: MapSet.new(), do: n["id"]

    socket =
      assign(socket,
        nodes: nodes,
        running_ids: running_ids,
        outdated: outdated,
        latest_node: latest
      )

    assign(socket, running: running?(socket), target: target_node(socket))
  end

  defp load_tailnet(socket), do: assign(socket, tailnet: Photon.Tailnet.status())

  defp running?(%{assigns: %{session: nil}}), do: false

  defp running?(socket),
    do: MapSet.member?(socket.assigns.running_ids, socket.assigns.session["id"])

  # The node a message would run on: the session's, or the one picked for new sessions.
  # A session stays on its node; a new one uses the chosen node if it's
  # connected, else any connected node (on a fresh hub, "local" may be off).
  defp target_node(%{assigns: %{session: %{"node" => id}}} = socket) do
    %{id: id, info: Enum.find(socket.assigns.nodes, &(&1["id"] == id))}
  end

  defp target_node(socket) do
    nodes = socket.assigns.nodes
    chosen = Enum.find(nodes, &(&1["id"] == socket.assigns.settings["node"]))

    case chosen || List.first(nodes) do
      nil -> %{id: socket.assigns.settings["node"], info: nil}
      node -> %{id: node["id"], info: node}
    end
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket = assign(socket, server_uri: URI.parse(uri))
    handle_route(params, socket)
  end

  defp handle_route(%{"id" => id}, socket) do
    cond do
      socket.assigns.session && socket.assigns.session["id"] == id ->
        {:noreply, socket}

      session = Sessions.get(id) ->
        {:noreply, open_session(socket, session)}

      true ->
        {:noreply, socket |> put_flash(:error, "Session not found") |> push_patch(to: ~p"/")}
    end
  end

  defp handle_route(_params, socket) do
    {:noreply, close_session(socket) |> assign(page_title: "New session") |> assign_nodes()}
  end

  defp open_session(socket, session) do
    socket = close_session(socket)
    id = session["id"]
    if connected?(socket), do: Phoenix.PubSub.subscribe(Photon.PubSub, Sessions.topic(id))
    events = Sessions.events(id)

    socket
    |> assign(
      session: session,
      transcript: Transcript.build(events),
      raw: events |> Enum.take(-@raw_limit) |> Enum.reverse(),
      page_title: session["title"]
    )
    |> assign_nodes()
  end

  defp close_session(%{assigns: %{session: nil}} = socket), do: socket

  defp close_session(socket) do
    Phoenix.PubSub.unsubscribe(Photon.PubSub, Sessions.topic(socket.assigns.session["id"]))
    assign(socket, session: nil, transcript: Transcript.new(), raw: [], running: false)
  end

  @impl true
  def handle_event("send", %{"prompt" => prompt}, socket) do
    prompt = String.trim(prompt)
    images = socket.assigns.uploads.images.entries

    cond do
      (prompt == "" and images == []) or socket.assigns.running ->
        {:noreply, socket}

      Enum.any?(images, &(!&1.done?)) ->
        {:noreply, put_flash(socket, :error, "Wait for the images to finish uploading.")}

      socket.assigns.target.info == nil ->
        {:noreply, put_flash(socket, :error, "Node #{socket.assigns.target.id} is offline.")}

      # Older nodes ignore images, which would leave the agent pointed at files
      # that were never written. The images stay in the composer.
      images != [] and "attachments" not in (socket.assigns.target.info["capabilities"] || []) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Node #{socket.assigns.target.id} needs an update to receive images: open Add a node and click Update."
         )}

      true ->
        socket = ensure_session(socket, if(prompt == "", do: "Image", else: prompt))
        %{"id" => id, "node" => node_id} = socket.assigns.session
        attachments = consume_images(socket, id)
        prompt = Attachments.with_note(prompt, Enum.map(attachments, &elem(&1, 0)))
        config = Settings.run_config(socket.assigns.settings)

        case Nodes.start_run(node_id, id, prompt, config, attachments) do
          :ok ->
            {:noreply,
             socket
             |> assign(running: true)
             |> push_event("composer:clear", %{})
             |> push_patch(to: ~p"/s/#{id}")}

          {:error, :offline} ->
            {:noreply,
             socket
             |> put_flash(:error, "Node #{node_id} went offline.")
             |> push_patch(to: ~p"/s/#{id}")}
        end
    end
  end

  # Uploads validate through the form's change event; nothing else to do.
  def handle_event("composer", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_image", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :images, ref)}
  end

  def handle_event("stop", _params, socket) do
    if session = socket.assigns.session, do: Nodes.stop_run(session["node"], session["id"])
    {:noreply, socket}
  end

  def handle_event("delete_session", %{"id" => id}, socket) do
    if session = Sessions.get(id), do: Nodes.delete_session(session["node"], id)
    Sessions.delete(id)

    if socket.assigns.session && socket.assigns.session["id"] == id,
      do: {:noreply, push_patch(socket, to: ~p"/")},
      else: {:noreply, socket}
  end

  def handle_event("settings", %{"settings" => params}, socket) do
    enabled = Map.get(params, "enabled_tools", []) |> List.wrap()

    params =
      params
      |> Map.delete("enabled_tools")
      |> Map.put("disallowed_tools", Settings.tools() -- enabled)

    settings = Settings.save(Map.merge(socket.assigns.settings, params))
    {:noreply, socket |> assign(settings: settings) |> assign_nodes()}
  end

  def handle_event("pick_node", %{"node" => node_id}, socket) do
    settings = Settings.save(%{socket.assigns.settings | "node" => node_id})
    {:noreply, socket |> assign(settings: settings) |> assign_nodes()}
  end

  def handle_event("reset_settings", _params, socket) do
    settings = Settings.save(Settings.defaults())
    {:noreply, socket |> assign(settings: settings) |> assign_nodes()}
  end

  def handle_event("toggle_connect", _params, socket) do
    socket = update(socket, :show_connect, &(!&1))
    # Discovery shells out to tailscale, so it runs when the panel opens.
    {:noreply, if(socket.assigns.show_connect, do: load_tailnet(socket), else: socket)}
  end

  def handle_event("refresh_tailnet", _params, socket), do: {:noreply, load_tailnet(socket)}

  def handle_event("ssh_user", %{"ssh_user" => user}, socket) do
    {:noreply, assign(socket, ssh_user: String.trim(user))}
  end

  def handle_event("provision", %{"machine" => name, "action" => action}, socket)
      when action in ~w(install uninstall) do
    with {:ok, %{self: self_machine, peers: peers}} <- socket.assigns.tailnet,
         %{} = machine <- Enum.find(peers, &(&1.name == name)),
         {:ok, base} <- Photon.Hub.public_url(self_machine),
         :ok <-
           Photon.Provision.run(String.to_existing_atom(action),
             machine: machine.name,
             host: machine.dns,
             ssh_user: socket.assigns.ssh_user,
             node_id: machine.name,
             base_url: base
           ) do
      {:noreply, socket}
    else
      {:error, reason} when is_binary(reason) -> {:noreply, put_flash(socket, :error, reason)}
      _ -> {:noreply, put_flash(socket, :error, "Can't reach #{name} from this hub.")}
    end
  end

  def handle_event("tab", %{"tab" => tab}, socket) when tab in ~w(chat raw) do
    {:noreply, assign(socket, tab: String.to_existing_atom(tab))}
  end

  def handle_event("toggle_control", _params, socket) do
    {:noreply, update(socket, :show_control, &(!&1))}
  end

  def handle_event("toggle_settings", _params, socket) do
    {:noreply, update(socket, :show_settings, &(!&1))}
  end

  def handle_event("example", %{"prompt" => prompt}, socket) do
    handle_event("send", %{"prompt" => prompt}, socket)
  end

  # Keeps the hub's copy of each image and returns {workspace_path, bytes},
  # in the order they were added (entries come back newest first).
  defp consume_images(socket, session_id) do
    socket
    |> consume_uploaded_entries(:images, fn %{path: tmp}, entry ->
      path = Attachments.workspace_path(entry.client_name, entry.ref)
      data = File.read!(tmp)
      Attachments.save!(session_id, path, data)
      {:ok, {String.to_integer(entry.ref), path, data}}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_ref, path, data} -> {path, data} end)
  end

  defp ensure_session(%{assigns: %{session: nil}} = socket, prompt) do
    session = Sessions.create(title(prompt), socket.assigns.target.id)
    open_session(socket, session)
  end

  defp ensure_session(socket, prompt) do
    session = socket.assigns.session

    if session["title"] == "New session" do
      Sessions.rename(session["id"], title(prompt))
      assign(socket, session: %{session | "title" => title(prompt)})
    else
      socket
    end
  end

  defp title(prompt) do
    line = prompt |> String.split("\n", parts: 2) |> hd()
    if String.length(line) > 60, do: String.slice(line, 0, 57) <> "…", else: line
  end

  @impl true
  def handle_info({:runner_event, id, event}, %{assigns: %{session: %{"id" => id}}} = socket) do
    {:noreply,
     assign(socket,
       transcript: Transcript.apply_event(socket.assigns.transcript, event),
       raw: Enum.take([event | socket.assigns.raw], @raw_limit)
     )}
  end

  def handle_info(:nodes_changed, socket), do: {:noreply, assign_nodes(socket)}

  def handle_info({:provision, jobs}, socket), do: {:noreply, assign(socket, jobs: jobs)}

  def handle_info({:settings_changed, settings}, socket) do
    {:noreply, socket |> assign(settings: settings) |> assign_nodes()}
  end

  def handle_info(:sessions_changed, socket) do
    {:noreply, assign(socket, sessions: Sessions.list())}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex h-full">
        <.sidebar
          sessions={@sessions}
          session={@session}
          running_ids={@running_ids}
          nodes={@nodes}
          outdated={@outdated}
          latest_node={@latest_node}
        />

        <main class="flex min-w-0 flex-1 flex-col">
          <.topbar
            session={@session}
            target={@target}
            running={@running}
            transcript={@transcript}
            tab={@tab}
            show_control={@show_control}
            show_settings={@show_settings}
          />

          <.node_banner target={@target} session={@session} nodes={@nodes} />
          <.outdated_banner
            :if={@target.info && MapSet.member?(@outdated, @target.id)}
            node={@target.info}
            latest={@latest_node}
          />

          <div
            id="transcript"
            phx-hook=".ScrollBottom"
            class="flex-1 overflow-y-auto"
          >
            <div :if={@tab == :chat} class="mx-auto max-w-3xl space-y-4 px-6 py-6">
              <.empty_state :if={Transcript.entries(@transcript) == []} settings={@settings} />
              <.entry
                :for={entry <- Transcript.entries(@transcript)}
                entry={entry}
                show_control={@show_control}
                session_id={@session && @session["id"]}
              />
              <div :if={@running} class="ml-10 flex items-center gap-2 text-sm text-base-content/50">
                <span class="loading loading-dots loading-sm"></span> Agent is working
              </div>
            </div>
            <.raw_events :if={@tab == :raw} raw={@raw} />
          </div>

          <.composer
            uploads={@uploads}
            running={@running}
            disabled={!ready?(@target)}
            nodes={@nodes}
            target={@target}
            pick={@session == nil and @nodes != []}
          />
        </main>

        <.settings_panel :if={@show_settings} settings={@settings} target={@target} />
      </div>
      <.connect_panel
        :if={@show_connect}
        server_uri={@server_uri}
        tailnet={@tailnet}
        jobs={@jobs}
        nodes={@nodes}
        outdated={@outdated}
        ssh_user={@ssh_user}
      />
    </Layouts.app>
    """
  end

  attr :sessions, :list, required: true
  attr :session, :map, default: nil
  attr :running_ids, :any, required: true
  attr :nodes, :list, required: true
  attr :outdated, :any, required: true
  attr :latest_node, :string, default: nil

  defp sidebar(assigns) do
    ~H"""
    <aside class="flex w-64 shrink-0 flex-col border-r border-base-300 bg-base-200/60">
      <div class="flex items-center gap-2.5 px-4 pt-4 pb-3">
        <div class="flex size-8 items-center justify-center rounded-lg bg-gradient-to-br from-primary to-accent text-primary-content shadow-sm">
          <.icon name="hero-bolt-solid" class="size-4" />
        </div>
        <div class="leading-tight">
          <div class="text-sm font-semibold">Photon</div>
          <div class="text-[11px] text-base-content/50">unreal-agent playground</div>
        </div>
      </div>

      <div class="px-3 pb-2">
        <.link
          patch={~p"/"}
          class="flex w-full items-center justify-center gap-1.5 rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-sm font-medium shadow-xs transition hover:border-primary/50 hover:text-primary"
        >
          <.icon name="hero-plus-micro" class="size-4" /> New session
        </.link>
      </div>

      <nav class="flex-1 space-y-0.5 overflow-y-auto px-2 pb-3">
        <p :if={@sessions == []} class="px-3 py-6 text-center text-xs text-base-content/40">
          No sessions yet
        </p>
        <div
          :for={s <- @sessions}
          class={[
            "group relative flex items-center rounded-lg transition",
            if(@session && @session["id"] == s["id"],
              do: "bg-base-300 text-base-content",
              else: "text-base-content/70 hover:bg-base-300/50"
            )
          ]}
        >
          <.link patch={~p"/s/#{s["id"]}"} class="min-w-0 flex-1 px-3 py-2">
            <div class="flex items-center gap-2">
              <span
                :if={MapSet.member?(@running_ids, s["id"])}
                class="size-1.5 shrink-0 animate-pulse rounded-full bg-success"
              />
              <span class="truncate text-sm">{s["title"]}</span>
            </div>
            <div class="mt-0.5 flex gap-1.5 font-mono text-[10px] text-base-content/40">
              <span>{relative(s["updated_at"])}</span>
              <span :if={length(@nodes) > 1 or s["node"] != "local"}>· {s["node"]}</span>
            </div>
          </.link>
          <button
            phx-click="delete_session"
            phx-value-id={s["id"]}
            data-confirm="Delete this session and its history?"
            class="mr-1.5 hidden rounded p-1 text-base-content/40 group-hover:block hover:bg-base-100 hover:text-error"
            title="Delete session"
          >
            <.icon name="hero-trash-micro" class="size-3.5" />
          </button>
        </div>
      </nav>

      <.node_list nodes={@nodes} sessions={@sessions} outdated={@outdated} latest={@latest_node} />

      <div class="flex items-center justify-between border-t border-base-300 px-4 py-3">
        <a
          href="https://github.com/unreallabsai/unreal-agent"
          target="_blank"
          class="text-xs text-base-content/50 hover:text-base-content"
        >
          unreal-agent ↗
        </a>
        <Layouts.theme_toggle />
      </div>
    </aside>
    """
  end

  attr :session, :map
  attr :target, :map
  attr :running, :boolean
  attr :transcript, :any
  attr :tab, :atom
  attr :show_control, :boolean
  attr :show_settings, :boolean

  defp topbar(assigns) do
    ~H"""
    <header class="flex items-center gap-3 border-b border-base-300 px-6 py-3">
      <div class="min-w-0 flex-1">
        <h1 class="truncate text-[15px] font-semibold">
          {if @session, do: @session["title"], else: "New session"}
        </h1>
        <p
          :if={@session}
          class="flex items-center gap-2 truncate font-mono text-[11px] text-base-content/40"
        >
          <span class="flex items-center gap-1">
            <span class={[
              "size-1.5 rounded-full",
              if(@target.info, do: "bg-success", else: "bg-base-content/30")
            ]} />
            {@target.id}
          </span>
          <span class="truncate">session {@session["id"]}</span>
        </p>
      </div>

      <div
        :if={@session}
        class="hidden items-center gap-3 font-mono text-[11px] text-base-content/50 lg:flex"
        title="Totals across the session's model responses"
      >
        <span>{@transcript.responses} responses</span>
        <span>{fmt(@transcript.usage.input)} in</span>
        <span :if={@transcript.usage.cached > 0}>{fmt(@transcript.usage.cached)} cached</span>
        <span>{fmt(@transcript.usage.output)} out</span>
      </div>

      <span
        :if={@running}
        class="flex items-center gap-1.5 rounded-full bg-success/15 px-2.5 py-1 text-xs font-medium text-success"
      >
        <span class="size-1.5 animate-pulse rounded-full bg-success"></span> Running
      </span>

      <div class="flex rounded-lg bg-base-200 p-0.5 text-xs font-medium">
        <button
          :for={{tab, label} <- [chat: "Conversation", raw: "Raw events"]}
          phx-click="tab"
          phx-value-tab={tab}
          class={[
            "rounded-md px-2.5 py-1 transition",
            if(@tab == tab,
              do: "bg-base-100 shadow-xs",
              else: "text-base-content/60 hover:text-base-content"
            )
          ]}
        >
          {label}
        </button>
      </div>

      <button
        phx-click="toggle_control"
        class={[
          "rounded-lg p-1.5 transition hover:bg-base-200",
          if(@show_control, do: "text-primary", else: "text-base-content/50")
        ]}
        title="Show control inputs (settings, stop requests, heartbeats)"
      >
        <.icon name="hero-adjustments-horizontal" class="size-5" />
      </button>
      <button
        phx-click="toggle_settings"
        class={[
          "rounded-lg p-1.5 transition hover:bg-base-200",
          if(@show_settings, do: "text-primary", else: "text-base-content/50")
        ]}
        title="Settings"
      >
        <.icon name="hero-cog-6-tooth" class="size-5" />
      </button>
    </header>
    """
  end

  attr :settings, :map, required: true

  defp empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center py-16 text-center">
      <div class="flex size-12 items-center justify-center rounded-2xl bg-gradient-to-br from-primary/20 to-accent/20 text-primary">
        <.icon name="hero-bolt" class="size-6" />
      </div>
      <h2 class="mt-4 text-lg font-semibold">Try the Unreal Agent harness</h2>
      <p class="mt-1 max-w-md text-sm text-base-content/60">
        Each message runs <code class="font-mono">unreal-agent-runner</code>
        against your workspace and resumes the same session, so the conversation carries on.
        Tool calls run asynchronously and their results land as they finish.
      </p>
      <p :if={@settings["provider"] == "mock"} class="mt-3 text-xs text-base-content/50">
        You're on the built-in mock model. Pick a real provider in Settings when you're ready.
      </p>
      <div class="mt-6 grid w-full max-w-lg gap-2 sm:grid-cols-2">
        <button
          :for={{label, prompt} <- examples(@settings["provider"])}
          phx-click="example"
          phx-value-prompt={prompt}
          class="rounded-xl border border-base-300 bg-base-200/40 px-3.5 py-3 text-left text-sm transition hover:border-primary/40 hover:bg-base-200"
        >
          <div class="font-medium">{label}</div>
          <div class="mt-0.5 truncate font-mono text-xs text-base-content/50">{prompt}</div>
        </button>
      </div>
    </div>
    """
  end

  defp examples("mock") do
    [
      {"What can the mock do?", "help"},
      {"Run a command", "$ uname -a && date"},
      {"Watch an async tool", "sleep 5"},
      {"Look around", "What's in the workspace?"}
    ]
  end

  defp examples(_provider) do
    [
      {"Explore", "Inspect this workspace and summarize what's here."},
      {"Write code", "Write a Python script that prints the first 20 primes, then run it."},
      {"Parallel tools",
       "Run `sleep 3; echo a` and `sleep 1; echo b` at the same time and tell me which finished first."},
      {"System info", "What OS and tools are available in this environment?"}
    ]
  end

  attr :raw, :list, required: true

  defp raw_events(assigns) do
    ~H"""
    <div class="space-y-1.5 px-6 py-4 font-mono text-xs">
      <p :if={@raw == []} class="py-10 text-center text-base-content/40">No events yet</p>
      <p :if={@raw != []} class="pb-1 text-base-content/40">
        Newest first. These are the JSONL lines the runner wrote to stdout.
      </p>
      <details :for={event <- @raw} class="rounded-lg border border-base-300 bg-base-200/40">
        <summary class="flex cursor-pointer items-center gap-3 px-3 py-1.5 select-none">
          <span class="w-8 text-right text-base-content/40">{event["Sequence"]}</span>
          <span class={["rounded px-1.5 py-0.5", kind_class(event)]}>{event_kind(event)}</span>
          <span class="truncate text-base-content/60">{event_hint(event)}</span>
        </summary>
        <pre class="max-h-[32rem] overflow-auto border-t border-base-300 p-3 whitespace-pre-wrap break-all">{pretty(event)}</pre>
      </details>
    </div>
    """
  end

  attr :uploads, :map, required: true
  attr :running, :boolean
  attr :disabled, :boolean
  attr :nodes, :list
  attr :target, :map
  attr :pick, :boolean

  defp composer(assigns) do
    ~H"""
    <div class="border-t border-base-300 bg-base-100 px-6 py-4">
      <form id="composer-form" phx-submit="send" phx-change="composer" class="mx-auto max-w-3xl">
        <div
          phx-drop-target={@uploads.images.ref}
          class="rounded-2xl border border-base-300 bg-base-200/50 p-2 shadow-xs transition focus-within:border-primary/50 focus-within:ring-4 focus-within:ring-primary/10 [&.phx-drop-target-active]:border-primary [&.phx-drop-target-active]:bg-primary/5"
        >
          <.image_tray uploads={@uploads} />
          <div class="flex items-end gap-2">
            <label
              for={@uploads.images.ref}
              class={[
                "flex size-10 shrink-0 cursor-pointer items-center justify-center rounded-xl text-base-content/50 transition hover:bg-base-300/60 hover:text-base-content",
                @disabled && "pointer-events-none opacity-40"
              ]}
              title="Attach images (or paste, or drop them here)"
            >
              <.icon name="hero-photo" class="size-5" />
            </label>
            <.live_file_input upload={@uploads.images} class="sr-only" />
            <textarea
              id="composer"
              name="prompt"
              rows="1"
              phx-hook=".Composer"
              phx-debounce="blur"
              placeholder={
                if @running,
                  do: "Waiting for the agent to finish…",
                  else: "Message the agent  (Enter to send, Shift+Enter for a new line)"
              }
              disabled={@disabled}
              class="max-h-48 min-h-[2.5rem] flex-1 resize-none bg-transparent px-2 py-2 text-[15px] outline-none placeholder:text-base-content/40"
            ></textarea>
            <button
              :if={!@running}
              type="submit"
              disabled={@disabled}
              class="flex size-10 shrink-0 items-center justify-center rounded-xl bg-primary text-primary-content transition hover:brightness-110 disabled:opacity-40"
              title="Send"
            >
              <.icon name="hero-arrow-up" class="size-5" />
            </button>
            <button
              :if={@running}
              type="button"
              phx-click="stop"
              class="flex size-10 shrink-0 items-center justify-center rounded-xl bg-base-content text-base-100 transition hover:opacity-80"
              title="Stop (sends SIGINT to the runner)"
            >
              <.icon name="hero-stop-solid" class="size-4" />
            </button>
          </div>
        </div>
      </form>
      <form
        :if={@pick}
        id="node-picker"
        phx-change="pick_node"
        phx-auto-recover="ignore"
        class="mx-auto mt-2 flex max-w-3xl items-center gap-2 px-1 text-xs text-base-content/50"
      >
        <.icon name="hero-server-stack-micro" class="size-3.5" />
        <span>Run on</span>
        <select
          name="node"
          class="rounded-md border border-base-300 bg-base-100 px-1.5 py-0.5 font-mono text-xs text-base-content outline-none focus:border-primary/60"
        >
          <option :for={node <- @nodes} value={node["id"]} selected={node["id"] == @target.id}>
            {node["id"]}{if node["hostname"] && node["hostname"] != node["id"],
              do: " (#{node["hostname"]})"}
          </option>
          <option :if={@target.info == nil} value={@target.id} selected>
            {@target.id} (offline)
          </option>
        </select>
      </form>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Composer">
      export default {
        mounted() {
          const resize = () => {
            this.el.style.height = "auto"
            this.el.style.height = this.el.scrollHeight + "px"
          }
          this.el.addEventListener("input", resize)
          this.el.addEventListener("keydown", (e) => {
            if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
              e.preventDefault()
              this.el.form.requestSubmit()
            }
          })
          // Images pasted from the clipboard join the same upload as picked
          // or dropped ones.
          this.el.addEventListener("paste", (e) => {
            const files = [...(e.clipboardData?.files || [])].filter((f) => f.type.startsWith("image/"))
            if (files.length > 0) {
              e.preventDefault()
              this.upload("images", files)
            }
          })
          this.handleEvent("composer:clear", () => {
            this.el.value = ""
            resize()
          })
        }
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollBottom">
      export default {
        mounted() {
          this.pinned = true
          this.el.addEventListener("scroll", () => {
            this.pinned = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 80
          })
          this.el.scrollTop = this.el.scrollHeight
        },
        beforeUpdate() {
          this.pinned = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 80
        },
        updated() {
          if (this.pinned) this.el.scrollTop = this.el.scrollHeight
        }
      }
    </script>
    """
  end

  attr :uploads, :map, required: true

  defp image_tray(assigns) do
    ~H"""
    <div
      :if={@uploads.images.entries != [] or upload_errors(@uploads.images) != []}
      class="flex flex-wrap gap-2 px-1 pt-1 pb-2"
    >
      <div
        :for={entry <- @uploads.images.entries}
        class="group relative size-16 overflow-hidden rounded-lg border border-base-300 bg-base-300"
      >
        <.live_img_preview entry={entry} class="size-full object-cover" />
        <div
          :if={!entry.done?}
          class="absolute inset-x-1 bottom-1 h-1 overflow-hidden rounded-full bg-base-100/60"
        >
          <div class="h-full bg-primary transition-all" style={"width: #{entry.progress}%"} />
        </div>
        <div
          :for={err <- upload_errors(@uploads.images, entry)}
          class="absolute inset-0 flex items-center justify-center bg-error/80 p-1 text-center text-[10px] leading-tight text-error-content"
        >
          {upload_error_text(err)}
        </div>
        <button
          type="button"
          phx-click="cancel_image"
          phx-value-ref={entry.ref}
          class="absolute top-0.5 right-0.5 hidden rounded-full bg-base-100/80 p-0.5 text-base-content group-hover:block"
          title="Remove"
        >
          <.icon name="hero-x-mark-micro" class="size-3.5" />
        </button>
      </div>
      <p
        :for={err <- upload_errors(@uploads.images)}
        class="self-center text-xs text-error"
      >
        {upload_error_text(err)}
      </p>
    </div>
    """
  end

  defp upload_error_text(:too_large), do: "Over 10 MB"
  defp upload_error_text(:not_accepted), do: "PNG, JPEG or WebP only"
  defp upload_error_text(:too_many_files), do: "Up to 4 images per message"
  defp upload_error_text(other), do: to_string(other)

  attr :settings, :map, required: true
  attr :target, :map, required: true

  defp settings_panel(assigns) do
    info = assigns.target.info || %{}

    assigns =
      assign(assigns,
        provider: assigns.settings["provider"],
        key_env: Settings.provider_key_env(assigns.settings["provider"]),
        node_keys: info["key_envs"] || [],
        node_workspace: info["workspace"]
      )

    ~H"""
    <aside class="flex w-80 shrink-0 flex-col border-l border-base-300 bg-base-200/40">
      <div class="flex items-center justify-between px-5 pt-4 pb-2">
        <h2 class="text-sm font-semibold">Settings</h2>
        <button
          phx-click="reset_settings"
          data-confirm="Reset all settings to defaults?"
          class="text-xs text-base-content/50 hover:text-base-content"
        >
          Reset
        </button>
      </div>

      <form
        id="settings-form"
        phx-change="settings"
        phx-auto-recover="ignore"
        class="flex-1 space-y-4 overflow-y-auto px-5 pb-6"
      >
        <.field label="Provider">
          <select name="settings[provider]" class={field_class()}>
            <option
              :for={{value, label} <- Settings.providers()}
              value={value}
              selected={value == @provider}
            >
              {label}
            </option>
          </select>
          <:hint :if={@provider == "mock"}>
            Served by this server at <code>/mock/v1</code>, which nodes reach through the same host they connect to. Scripted, but it drives the real harness and tools.
          </:hint>
          <:hint :if={@provider == "openai-codex"}>
            Uses your Codex login from <code>~/.codex/auth.json</code>, or <code>OPENAI_CODEX_*</code>
            env vars.
          </:hint>
          <:hint :if={@provider == "ollama"}>
            Defaults to <code>http://localhost:11434/v1</code>.
          </:hint>
        </.field>

        <div :if={@provider != "mock"} class="space-y-4">
          <.field label="Model">
            <input
              name="settings[model]"
              value={@settings["model"]}
              placeholder={model_placeholder(@provider)}
              phx-debounce="400"
              class={field_class()}
            />
          </.field>

          <.field :if={@key_env} label="API key">
            <input
              type="password"
              name="settings[api_key]"
              value={@settings["api_key"]}
              placeholder={"Uses $#{@key_env} when blank"}
              phx-debounce="400"
              autocomplete="off"
              class={field_class()}
            />
            <:hint>
              <span :if={@settings["api_key"] == "" and @key_env in @node_keys} class="text-success">
                ✓ ${@key_env} is set on node {@target.id}.
              </span>
              <span
                :if={@settings["api_key"] == "" and @key_env not in @node_keys}
                class="text-warning"
              >
                ${@key_env} isn't set on node {@target.id}. Paste a key here, or export it where the node runs.
              </span>
              <span :if={@settings["api_key"] != ""}>
                Saved in <code>.photon/settings.json</code> and sent to the node with each run.
              </span>
            </:hint>
          </.field>

          <.field label="Base URL">
            <input
              name="settings[base_url]"
              value={@settings["base_url"]}
              placeholder="Provider default"
              phx-debounce="400"
              class={field_class()}
            />
          </.field>
        </div>

        <.field label="Thinking level">
          <div class="grid grid-cols-5 gap-1 rounded-lg bg-base-300/50 p-0.5">
            <label
              :for={level <- Settings.thinking_levels()}
              class={[
                "cursor-pointer rounded-md py-1 text-center text-xs transition",
                if(@settings["thinking_level"] == level,
                  do: "bg-base-100 font-medium shadow-xs",
                  else: "text-base-content/60 hover:text-base-content"
                )
              ]}
            >
              <input
                type="radio"
                name="settings[thinking_level]"
                value={level}
                checked={@settings["thinking_level"] == level}
                class="sr-only"
              />
              {level}
            </label>
          </div>
        </.field>

        <.field label="Tools">
          <input type="hidden" name="settings[enabled_tools][]" value="" />
          <div class="space-y-1.5">
            <label :for={tool <- Settings.tools()} class="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                name="settings[enabled_tools][]"
                value={tool}
                checked={tool not in @settings["disallowed_tools"]}
                class="checkbox checkbox-xs checkbox-primary"
              />
              <span class="font-mono">{tool}</span>
            </label>
          </div>
          <:hint>
            SkillUse turns on automatically when <code>.harness/skills</code> exists in the workspace.
          </:hint>
        </.field>

        <.field label="Workspace">
          <input
            name="settings[workspace]"
            value={@settings["workspace"]}
            placeholder={@node_workspace || "Node default"}
            phx-debounce="400"
            class={[field_class(), "font-mono text-xs"]}
          />
          <:hint>
            A path on the node, where the agent runs Bash unsandboxed. Blank uses the node's default.
          </:hint>
        </.field>

        <.field label="System prompt">
          <textarea
            name="settings[system_prompt]"
            rows="4"
            placeholder="Runner default"
            phx-debounce="400"
            class={[field_class(), "resize-y text-xs"]}
          >{@settings["system_prompt"]}</textarea>
        </.field>

        <.field label="Max attempts">
          <input
            name="settings[max_attempts]"
            value={@settings["max_attempts"]}
            inputmode="numeric"
            placeholder="5"
            phx-debounce="400"
            class={field_class()}
          />
          <:hint>Retries per LLM request. 1 disables retries.</:hint>
        </.field>
      </form>
    </aside>
    """
  end

  defp ready?(%{info: %{"runner" => runner}}) when is_binary(runner), do: true
  defp ready?(_target), do: false

  attr :target, :map, required: true
  attr :session, :map
  attr :nodes, :list, default: []

  defp node_banner(%{session: nil, nodes: []} = assigns) do
    ~H"""
    <div class="mx-6 mt-4 flex items-start gap-3 rounded-xl border border-info/40 bg-info/10 px-4 py-3 text-sm">
      <.icon name="hero-server-stack" class="mt-0.5 size-5 shrink-0 text-info" />
      <div class="flex-1">
        <p class="font-medium">No nodes are connected yet.</p>
        <p class="mt-0.5 text-base-content/70">
          Agents run on nodes: machines that connect to this hub. Add one to start a session.
        </p>
      </div>
      <button
        phx-click="toggle_connect"
        class="shrink-0 rounded-lg bg-primary px-3 py-1.5 text-xs font-medium text-primary-content hover:brightness-110"
      >
        Add a node
      </button>
    </div>
    """
  end

  defp node_banner(assigns) do
    ~H"""
    <div
      :if={!ready?(@target)}
      class="mx-6 mt-4 flex items-start gap-3 rounded-xl border border-warning/40 bg-warning/10 px-4 py-3 text-sm"
    >
      <.icon name="hero-server-stack" class="mt-0.5 size-5 shrink-0 text-warning" />
      <div :if={@target.info == nil}>
        <p class="font-medium">
          Node <code class="font-mono">{@target.id}</code> is offline.
        </p>
        <p class="mt-0.5 text-base-content/70">
          {if @session,
            do:
              "This session lives on that node. Its history is here, but new messages wait until it reconnects.",
            else: "Pick another node below, or connect one."} Runs already in progress keep going on the node and catch up when it reconnects.
        </p>
      </div>
      <div :if={@target.info}>
        <p class="font-medium">
          Node <code class="font-mono">{@target.id}</code>
          has no <code class="font-mono">unreal-agent-runner</code>.
        </p>
        <p class="mt-0.5 text-base-content/70">
          On that machine, run
          <code class="rounded bg-base-300 px-1 font-mono">mix photon.build_runner</code>
          (needs Go 1.27+), or set <code class="font-mono">PHOTON_RUNNER</code>, then restart the node.
        </p>
      </div>
    </div>
    """
  end

  attr :node, :map, required: true
  attr :latest, :string, default: nil

  defp outdated_banner(assigns) do
    ~H"""
    <div class="mx-6 mt-4 flex items-start gap-3 rounded-xl border border-warning/40 bg-warning/10 px-4 py-3 text-sm">
      <.icon name="hero-arrow-up-circle" class="mt-0.5 size-5 shrink-0 text-warning" />
      <div class="flex-1">
        <p class="font-medium">
          Node <code class="font-mono">{@node["id"]}</code> is out of date.
        </p>
        <p class="mt-0.5 text-base-content/70">
          It runs photon-node {@node["version"] || "(unknown)"}{if @latest,
            do: "; this hub has #{@latest}"}. Older nodes may miss features, such as receiving images.
        </p>
      </div>
      <button
        phx-click="toggle_connect"
        class="shrink-0 rounded-lg bg-warning px-3 py-1.5 text-xs font-medium text-warning-content hover:brightness-110"
      >
        Update
      </button>
    </div>
    """
  end

  attr :nodes, :list, required: true
  attr :sessions, :list, required: true
  attr :outdated, :any, default: MapSet.new()
  attr :latest, :string, default: nil

  defp node_list(assigns) do
    online = MapSet.new(assigns.nodes, & &1["id"])

    offline =
      assigns.sessions
      |> Enum.map(& &1["node"])
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(online, &1))
      |> Enum.sort()

    assigns = assign(assigns, offline: offline)

    ~H"""
    <div class="border-t border-base-300 px-2 py-2">
      <div class="flex items-center justify-between px-2 pb-1">
        <span class="text-[11px] font-semibold tracking-wide text-base-content/50 uppercase">Nodes</span>
        <button
          phx-click="toggle_connect"
          class="rounded p-0.5 text-base-content/50 hover:bg-base-300 hover:text-base-content"
          title="Connect a node"
        >
          <.icon name="hero-plus-micro" class="size-4" />
        </button>
      </div>
      <div
        :for={node <- @nodes}
        class="flex items-center gap-2 rounded-lg px-2 py-1.5 text-sm"
        title={"#{node["hostname"]} · #{node["platform"]}\nphoton-node #{node["version"]}#{if MapSet.member?(@outdated, node["id"]), do: " (this hub has #{@latest || "a newer one"})"}\nworkspace #{node["workspace"]}\nrunner #{node["runner"] || "missing"}"}
      >
        <span class="size-2 shrink-0 rounded-full bg-success" />
        <span class="min-w-0 flex-1 truncate font-mono text-xs">{node["id"]}</span>
        <button
          :if={MapSet.member?(@outdated, node["id"])}
          phx-click="toggle_connect"
          class="flex items-center gap-0.5 rounded bg-warning/15 px-1.5 py-0.5 text-[10px] font-medium text-warning hover:bg-warning/25"
          title="This node is out of date. Update it from Add a node."
        >
          <.icon name="hero-arrow-up-circle-micro" class="size-3" /> update
        </button>
        <span :if={MapSet.size(node["running"]) > 0} class="font-mono text-[10px] text-success">
          {MapSet.size(node["running"])} running
        </span>
        <.icon
          :if={!node["runner"]}
          name="hero-exclamation-triangle-micro"
          class="size-3.5 text-warning"
        />
      </div>
      <div
        :for={id <- @offline}
        class="flex items-center gap-2 px-2 py-1.5 text-sm text-base-content/40"
      >
        <span class="size-2 shrink-0 rounded-full border border-base-content/30" />
        <span class="min-w-0 flex-1 truncate font-mono text-xs">{id}</span>
        <span class="text-[10px]">offline</span>
      </div>
      <p :if={@nodes == [] and @offline == []} class="px-2 py-1 text-xs text-base-content/40">
        No nodes connected
      </p>
    </div>
    """
  end

  attr :server_uri, :any, required: true
  attr :tailnet, :any, required: true
  attr :jobs, :map, required: true
  attr :nodes, :list, required: true
  attr :ssh_user, :string, required: true
  attr :outdated, :any, default: MapSet.new()

  defp connect_panel(assigns) do
    self_machine = match?({:ok, _}, assigns.tailnet) && elem(assigns.tailnet, 1).self
    hub = Photon.Hub.public_url(self_machine || nil)
    base = with {:ok, base} <- hub, do: base
    uri = assigns.server_uri || %URI{host: "localhost", port: 4000, scheme: "http"}
    manual_base = if is_binary(base), do: base, else: "#{uri.scheme}://#{uri.host}:#{uri.port}"

    assigns =
      assign(assigns,
        hub: hub,
        base: base,
        manual_base: manual_base,
        self_machine: self_machine,
        built: Photon.NodeDist.available(),
        token: Photon.NodeAuth.token(),
        node_ids: MapSet.new(assigns.nodes, & &1["id"])
      )

    ~H"""
    <div
      class="fixed inset-0 z-40 flex items-start justify-center overflow-y-auto bg-black/40 p-4 sm:items-center"
      phx-click="toggle_connect"
    >
      <div
        class="w-full max-w-3xl rounded-2xl border border-base-300 bg-base-100 p-6 shadow-xl"
        phx-click={%Phoenix.LiveView.JS{}}
      >
        <div class="flex items-start justify-between">
          <div>
            <h2 class="text-base font-semibold">Add a node</h2>
            <p class="mt-1 text-sm text-base-content/60">
              A node runs agent harnesses on its machine and connects back to this hub. It's a
              single file with nothing to install alongside it, set up as a user service.
            </p>
          </div>
          <button
            phx-click="toggle_connect"
            class="rounded p-1 text-base-content/50 hover:bg-base-200"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <div class="mt-5 flex items-center justify-between">
          <h3 class="text-xs font-semibold tracking-wide text-base-content/60 uppercase">
            Your tailnet
          </h3>
          <button
            phx-click="refresh_tailnet"
            class="flex items-center gap-1 rounded px-1.5 py-0.5 text-xs text-base-content/50 hover:bg-base-200 hover:text-base-content"
          >
            <.icon name="hero-arrow-path-micro" class="size-3.5" /> Refresh
          </button>
        </div>

        <.hub_status hub={@hub} self_machine={@self_machine} built={@built} />

        <div
          :if={match?({:error, _}, @tailnet)}
          class="mt-3 rounded-lg bg-base-200 px-3 py-2 text-sm text-base-content/60"
        >
          {elem(@tailnet, 1)}. You can still add machines with the command below.
        </div>

        <form
          :if={match?({:ok, _}, @tailnet)}
          id="ssh-user-form"
          phx-change="ssh_user"
          phx-auto-recover="ignore"
          class="mt-3 flex items-center gap-2 text-xs text-base-content/60"
        >
          <label for="ssh-user">SSH as</label>
          <input
            id="ssh-user"
            name="ssh_user"
            value={@ssh_user}
            placeholder={System.get_env("PHOTON_SSH_USER") || "your ssh default"}
            phx-debounce="300"
            class="w-40 rounded-md border border-base-300 bg-base-100 px-2 py-1 font-mono text-xs outline-none focus:border-primary/60"
          />
          <span>Installs over SSH from this hub, so Tailscale SSH or your keys must allow it.</span>
        </form>

        <div
          :if={match?({:ok, _}, @tailnet)}
          class="mt-3 divide-y divide-base-300 rounded-xl border border-base-300"
        >
          <div :if={@self_machine} class="flex items-center gap-3 px-3 py-2.5 text-sm">
            <span class="size-2 shrink-0 rounded-full bg-success" />
            <span class="font-mono">{@self_machine.name}</span>
            <span class="text-xs text-base-content/50">
              {if Application.get_env(:photon, :local_node),
                do: "this hub, running the built-in local node",
                else: "this hub"}
            </span>
          </div>
          <.machine
            :for={m <- elem(@tailnet, 1).peers}
            machine={m}
            job={@jobs[m.name]}
            node?={MapSet.member?(@node_ids, m.name)}
            outdated?={MapSet.member?(@outdated, m.name)}
            can_install={is_binary(@base) and @built != []}
          />
        </div>

        <details class="group mt-5">
          <summary class="flex cursor-pointer list-none items-center gap-1.5 text-xs font-semibold tracking-wide text-base-content/60 uppercase select-none">
            <.icon name="hero-chevron-right-micro" class="size-4 transition group-open:rotate-90" />
            Any other machine
          </summary>
          <p class="mt-2 mb-1.5 text-xs text-base-content/60">
            Run this on the machine (or put it in a VPS's cloud-init). It downloads the right
            binary from this hub and sets up a user service:
          </p>
          <pre class="overflow-x-auto rounded-lg bg-base-200 p-3 font-mono text-[12.5px] leading-relaxed select-all">curl -fsSL {@manual_base}/node/install.sh | PHOTON_NODE_TOKEN={@token} sh</pre>
          <p class="mt-2 text-xs text-base-content/50">
            Remove it with <code class="font-mono">curl -fsSL {@manual_base}/node/install.sh | PHOTON_ACTION=uninstall sh</code>.
            To run from source instead, see the README.
          </p>
        </details>

        <p class="mt-5 text-xs leading-relaxed text-base-content/50">
          The token (in <code class="font-mono">.photon/node-token</code>) lets a machine join as a node,
          and anyone using this GUI can run commands on every node. Runs survive the hub restarting:
          nodes keep their own event log and replay what the hub missed when they reconnect.
        </p>
      </div>
    </div>
    """
  end

  attr :hub, :any, required: true
  attr :self_machine, :any, required: true
  attr :built, :list, required: true

  defp hub_status(assigns) do
    ~H"""
    <div :if={match?({:ok, _}, @hub)} class="mt-2 text-xs text-base-content/50">
      Nodes will connect to <code class="font-mono">{Photon.Hub.node_socket_url(elem(@hub, 1))}</code>
    </div>
    <div
      :if={@hub == {:error, :loopback}}
      class="mt-2 rounded-lg bg-warning/10 px-3 py-2 text-xs leading-relaxed text-warning"
    >
      The hub only listens on this machine, so nodes elsewhere can't reach it. Restart it on its
      tailnet address: <code class="font-mono">PHOTON_BIND={(@self_machine && @self_machine.ip) || "0.0.0.0"} mix phx.server</code>,
      or set <code class="font-mono">PHOTON_PUBLIC_URL</code>
      if it's behind <code class="font-mono">tailscale serve</code>.
    </div>
    <div
      :if={@hub == {:error, :no_address}}
      class="mt-2 rounded-lg bg-warning/10 px-3 py-2 text-xs text-warning"
    >
      The hub isn't on a tailnet, so set <code class="font-mono">PHOTON_PUBLIC_URL</code>
      to the URL nodes should use.
    </div>
    <div :if={@built == []} class="mt-2 rounded-lg bg-warning/10 px-3 py-2 text-xs text-warning">
      No node binaries are built yet. Build them on the hub with
      <code class="font-mono">mix photon.package</code>
      (see the README for its requirements).
    </div>
    """
  end

  attr :machine, :map, required: true
  attr :job, :map, default: nil
  attr :node?, :boolean, required: true
  attr :outdated?, :boolean, default: false
  attr :can_install, :boolean, required: true

  defp machine(assigns) do
    assigns = assign(assigns, busy: match?(%{status: :running}, assigns.job))

    ~H"""
    <div class="px-3 py-2.5">
      <div class="flex items-center gap-3 text-sm">
        <span class={[
          "size-2 shrink-0 rounded-full",
          if(@machine.online, do: "bg-success", else: "border border-base-content/30")
        ]} />
        <span class={["font-mono", !@machine.online && "text-base-content/50"]}>{@machine.name}</span>
        <span class="rounded bg-base-200 px-1.5 py-0.5 text-[11px] text-base-content/60">{@machine.os}</span>
        <span :if={@machine.tailscale_ssh} class="text-[11px] text-base-content/40">Tailscale SSH</span>
        <span :if={@node? and !@outdated?} class="flex items-center gap-1 text-[11px] text-success">
          <.icon name="hero-check-circle-micro" class="size-3.5" /> connected node
        </span>
        <span :if={@outdated?} class="flex items-center gap-1 text-[11px] text-warning">
          <.icon name="hero-arrow-up-circle-micro" class="size-3.5" /> update available
        </span>
        <span class="flex-1" />
        <span :if={!@machine.installable} class="text-[11px] text-base-content/40">not supported</span>
        <span :if={@machine.installable and !@machine.online} class="text-[11px] text-base-content/40">offline</span>
        <span :if={@busy} class="loading loading-spinner loading-xs text-base-content/50" />
        <div :if={@machine.installable and @machine.online} class="flex gap-1.5">
          <button
            phx-click="provision"
            phx-value-machine={@machine.name}
            phx-value-action="install"
            disabled={@busy or !@can_install}
            class="rounded-md bg-primary px-2.5 py-1 text-xs font-medium text-primary-content transition hover:brightness-110 disabled:opacity-40"
          >
            {if @node?, do: "Update", else: "Install"}
          </button>
          <button
            :if={@node?}
            phx-click="provision"
            phx-value-machine={@machine.name}
            phx-value-action="uninstall"
            disabled={@busy}
            data-confirm={"Remove the node from #{@machine.name}? Its sessions stay here, read-only."}
            class="rounded-md border border-base-300 px-2.5 py-1 text-xs transition hover:border-error/50 hover:text-error disabled:opacity-40"
          >
            Uninstall
          </button>
        </div>
      </div>
      <div
        :if={@job}
        class={[
          "mt-2 rounded-lg px-2.5 py-2 font-mono text-[11.5px] leading-relaxed whitespace-pre-wrap break-all",
          @job.status == :error && "bg-error/10 text-error",
          @job.status == :ok && "bg-success/10 text-base-content/80",
          @job.status == :running && "bg-base-200 text-base-content/70"
        ]}
      >
        {@job.log |> Enum.take(12) |> Enum.reverse() |> Enum.join("\n")}
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true
  slot :hint

  defp field(assigns) do
    ~H"""
    <div>
      <div class="mb-1.5 text-xs font-medium text-base-content/70">{@label}</div>
      {render_slot(@inner_block)}
      <p
        :for={hint <- @hint}
        class="mt-1.5 text-[11px] leading-snug text-base-content/50 [&_code]:font-mono"
      >
        {render_slot(hint)}
      </p>
    </div>
    """
  end

  defp field_class do
    "w-full rounded-lg border border-base-300 bg-base-100 px-2.5 py-1.5 text-sm outline-none transition focus:border-primary/60 focus:ring-2 focus:ring-primary/15"
  end

  defp model_placeholder("openai"), do: "gpt-6-astra (default)"
  defp model_placeholder(_), do: "Required"

  defp event_kind(%{"Kind" => kind}), do: kind
  defp event_kind(%{"type" => type}), do: type
  defp event_kind(_), do: "?"

  defp kind_class(%{"type" => "error"}), do: "bg-error/15 text-error"
  defp kind_class(%{"type" => _}), do: "bg-base-300 text-base-content/70"
  defp kind_class(%{"Kind" => "model_response"}), do: "bg-primary/15 text-primary"
  defp kind_class(%{"Kind" => "tool_call_status"}), do: "bg-info/15 text-info"
  defp kind_class(%{"Kind" => "input"}), do: "bg-success/15 text-success"
  defp kind_class(_), do: "bg-base-300 text-base-content/70"

  defp event_hint(%{"Kind" => "input", "Data" => d}),
    do: "#{d["Kind"]} #{inspect_payload(d["Payload"])}"

  defp event_hint(%{"Kind" => "turn", "Data" => d}), do: "#{d["Type"]} #{d["ID"]}"

  defp event_hint(%{"Kind" => "model_response", "Data" => d}) do
    types = Enum.map(d["Response"]["Output"] || [], & &1["Type"])
    "#{d["Response"]["Stop"]} · #{Enum.join(types, ", ")}"
  end

  defp event_hint(%{"Kind" => "tool_call_status", "Data" => d}) do
    ops = Enum.map_join(d["Operations"] || [], ", ", &"#{&1["Type"]}:#{&1["Status"]}")
    "#{d["CallID"]} #{ops}"
  end

  defp event_hint(%{"message" => m}), do: m
  defp event_hint(%{"status" => s}), do: "status #{s}"
  defp event_hint(_), do: ""

  defp inspect_payload(p) when is_binary(p), do: String.slice(p, 0, 120)
  defp inspect_payload(p), do: p |> Jason.encode!() |> String.slice(0, 120)

  defp pretty(event) do
    event |> truncate_blobs() |> Jason.encode!(pretty: true)
  end

  # Keep base64 images from swamping the inspector.
  defp truncate_blobs(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, truncate_blobs(v)} end)

  defp truncate_blobs(list) when is_list(list), do: Enum.map(list, &truncate_blobs/1)

  defp truncate_blobs(s) when is_binary(s) and byte_size(s) > 4000 do
    String.slice(s, 0, 200) <> "… (#{byte_size(s)} bytes)"
  end

  defp truncate_blobs(v), do: v

  defp fmt(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp fmt(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}k"
  defp fmt(n), do: to_string(n)

  defp relative(iso) do
    with {:ok, dt, _} <- DateTime.from_iso8601(iso || "") do
      seconds = DateTime.diff(DateTime.utc_now(), dt)

      cond do
        seconds < 60 -> "just now"
        seconds < 3600 -> "#{div(seconds, 60)}m ago"
        seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
        true -> Calendar.strftime(dt, "%b %-d")
      end
    else
      _ -> ""
    end
  end
end
