defmodule PhotonWeb.NodesLive do
  @moduledoc """
  The user's machines: connected nodes, one-click installs and updates over
  SSH for machines on the hub's tailnet (one machine at a time, or every
  outdated node at once), and a one-line installer for anywhere else, made
  per node since each node has its own key (`Photon.NodeKeys`).

  What the page shows is read into assigns when it mounts and when it hears
  a change (`:nodes_changed`, `:node_sessions_changed`, `{:provision, jobs}`);
  `tailscale status` runs in a task (`start_async/3`), so a slow tailnet
  doesn't hold up the page. `render/1` only derives from assigns.
  """

  use PhotonWeb, :live_view

  alias Photon.{NodeDist, NodeKeys, Nodes, NodeSessions, Provision, Tailnet}

  @max_counted_sessions 1000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        page_title: "Nodes",
        tailnet: :loading,
        hub: Photon.Hub.public_url(nil),
        jobs: Provision.jobs(),
        ssh_user: "",
        default_ssh_user: Provision.default_ssh_user(),
        latest: NodeDist.version(),
        built: NodeDist.available(),
        manual: nil,
        manual_form: to_form(%{"node_id" => ""}, as: :manual),
        server_uri: nil
      )
      |> assign_nodes()

    if connected?(socket) do
      Provision.subscribe()
      {:ok, load_tailnet(socket)}
    else
      {:ok, socket}
    end
  end

  # Connected nodes, how many sessions each has (up to a thousand), and
  # which run an older build than this hub hands out.
  defp assign_nodes(socket) do
    online = Nodes.list()

    assign(socket,
      online: online,
      node_ids: MapSet.new(online, & &1["id"]),
      session_counts:
        Map.new(online, &{&1["id"], NodeSessions.count(&1["id"], @max_counted_sessions)}),
      outdated:
        for(
          n <- online,
          NodeDist.outdated?(n, socket.assigns.latest),
          into: MapSet.new(),
          do: n["id"]
        )
    )
  end

  defp load_tailnet(socket), do: start_async(socket, :tailnet, fn -> Tailnet.status() end)

  @impl true
  def handle_params(_params, uri, socket),
    do: {:noreply, assign(socket, server_uri: URI.parse(uri))}

  @impl true
  def handle_event("refresh_tailnet", _params, socket) do
    socket = assign(socket, tailnet: :loading, hub: Photon.Hub.public_url(nil))
    {:noreply, load_tailnet(socket)}
  end

  def handle_event("ssh_user", %{"ssh_user" => user}, socket),
    do: {:noreply, assign(socket, ssh_user: String.trim(user))}

  # A key for a node installed by hand, shown once in its install command.
  def handle_event("manual_key", %{"manual" => %{"node_id" => node_id}}, socket) do
    node_id = String.trim(node_id)

    if Regex.match?(~r/\A[\w.-]{1,64}\z/, node_id) do
      {:ok, key} = NodeKeys.issue(node_id)

      {:noreply,
       assign(socket,
         manual: %{node_id: node_id, key: key},
         manual_form: to_form(%{"node_id" => node_id}, as: :manual)
       )}
    else
      {:noreply,
       put_flash(socket, :error, "Name it with letters, digits, dots, dashes or underscores.")}
    end
  end

  def handle_event("update_all", _params, socket) do
    failures =
      socket.assigns.outdated
      |> Enum.sort()
      |> Enum.flat_map(fn id ->
        case provision(socket.assigns, id, :install) do
          :ok -> []
          other -> ["#{id}: #{failure(other, id)}"]
        end
      end)

    case failures do
      [] -> {:noreply, socket}
      _ -> {:noreply, put_flash(socket, :error, "Couldn't update " <> Enum.join(failures, "; "))}
    end
  end

  def handle_event("provision", %{"machine" => name, "action" => action}, socket)
      when action in ~w(install uninstall) do
    case provision(socket.assigns, name, String.to_existing_atom(action)) do
      :ok -> {:noreply, socket}
      other -> {:noreply, put_flash(socket, :error, failure(other, name))}
    end
  end

  defp failure({:error, reason}, _name) when is_binary(reason), do: reason
  defp failure(_other, name), do: "This hub can't reach #{name}."

  # Starts a job for a tailnet machine, through the URL it reaches this hub at.
  defp provision(assigns, name, action) do
    with {:ok, %{self: self_machine, peers: peers}} <- assigns.tailnet,
         %{} = machine <- Enum.find(peers, &(&1.name == name)),
         {:ok, base} <- Photon.Hub.public_url(self_machine) do
      Provision.run(action,
        machine: machine.name,
        host: machine.dns,
        ssh_user: assigns.ssh_user,
        node_id: machine.name,
        base_url: base
      )
    end
  end

  @impl true
  def handle_async(:tailnet, {:ok, tailnet}, socket),
    do:
      {:noreply,
       assign(socket, tailnet: tailnet, hub: Photon.Hub.public_url(self_machine(tailnet)))}

  def handle_async(:tailnet, {:exit, reason}, socket) do
    tailnet = {:error, "couldn't read tailscale status (#{Exception.format_exit(reason)})"}
    {:noreply, assign(socket, tailnet: tailnet, hub: Photon.Hub.public_url(nil))}
  end

  @impl true
  def handle_info({:provision, jobs}, socket), do: {:noreply, assign(socket, jobs: jobs)}

  def handle_info(message, socket) when message in [:nodes_changed, :node_sessions_changed],
    do: {:noreply, assign_nodes(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp self_machine({:ok, %{self: self_machine}}), do: self_machine
  defp self_machine(_tailnet), do: nil

  @impl true
  def render(assigns) do
    uri = assigns.server_uri || %URI{host: "localhost", port: 4000, scheme: "http"}
    port = if uri.port in [80, 443, nil], do: "", else: ":#{uri.port}"

    manual_base =
      case assigns.hub do
        {:ok, base} -> base
        _ -> "#{uri.scheme}://#{uri.host}#{port}"
      end

    assigns =
      assign(assigns,
        base: match?({:ok, _}, assigns.hub) && elem(assigns.hub, 1),
        manual_base: manual_base,
        self_machine: self_machine(assigns.tailnet)
      )

    ~H"""
    <Layouts.app flash={@flash} shell={@shell} socket={@socket} active={:nodes}>
      <div class="h-full overflow-y-auto">
        <div class="blip-clear-y mx-auto w-full max-w-3xl px-4 py-8 sm:px-6">
          <.header>
            Nodes
            <:subtitle>
              Machines the assistant can work on. Each runs its own agent and connects back to this hub.
            </:subtitle>
          </.header>

          <section class="mt-7">
            <div class="flex items-center justify-between">
              <h2 class="text-[11px] font-semibold tracking-wider text-ink-faint uppercase">
                Connected
              </h2>
              <.button
                :if={MapSet.size(@outdated) > 0 and match?({:ok, _}, @tailnet)}
                id="update-all"
                size="sm"
                variant="primary"
                phx-click="update_all"
                disabled={!is_binary(@base) or @built == []}
              >
                Update all ({MapSet.size(@outdated)})
              </.button>
            </div>
            <p
              :if={@online == []}
              class="mt-3 rounded-xl border border-dashed border-line-strong px-4 py-6 text-center text-sm text-ink-faint"
            >
              No nodes are connected. Add one below.
            </p>
            <div class="mt-3 grid gap-3 sm:grid-cols-2">
              <div
                :for={node <- @online}
                id={"node-#{node["id"]}"}
                class="rounded-xl border border-line bg-surface p-4 shadow-xs"
              >
                <div class="flex items-center gap-2">
                  <.dot status={:ok} />
                  <span class="font-medium">{node["id"]}</span>
                  <span
                    :if={MapSet.member?(@outdated, node["id"])}
                    class="ml-auto rounded-full bg-warn-soft px-2 py-0.5 text-[11px] text-warn"
                  >
                    update available
                  </span>
                </div>
                <dl class="mt-3 space-y-1 text-[12.5px]">
                  <div class="flex gap-2">
                    <dt class="w-20 shrink-0 text-ink-faint">Platform</dt><dd class="truncate font-mono text-ink-soft">
                      {node["platform"]}
                    </dd>
                  </div>
                  <div class="flex gap-2">
                    <dt class="w-20 shrink-0 text-ink-faint">Workspace</dt><dd
                      class="truncate font-mono text-ink-soft"
                      title={node["workspace"]}
                    >
                      {node["workspace"]}
                    </dd>
                  </div>
                  <div class="flex gap-2">
                    <dt class="w-20 shrink-0 text-ink-faint">Version</dt><dd class="truncate font-mono text-ink-soft">
                      {node["version"]}
                    </dd>
                  </div>
                  <div class="flex gap-2">
                    <dt class="w-20 shrink-0 text-ink-faint">Sessions</dt><dd class="text-ink-soft">
                      {@session_counts[node["id"]]}
                    </dd>
                  </div>
                </dl>
              </div>
            </div>
          </section>

          <section id="add-node" class="mt-10">
            <div class="flex items-center justify-between">
              <h2 class="text-[11px] font-semibold tracking-wider text-ink-faint uppercase">
                Add a node from your tailnet
              </h2>
              <button
                phx-click="refresh_tailnet"
                class="flex items-center gap-1 rounded-md px-1.5 py-0.5 text-[12px] text-ink-faint hover:bg-sunken hover:text-ink"
              >
                <.icon name="hero-arrow-path-micro" class="size-3.5" /> Refresh
              </button>
            </div>
            <p class="mt-1.5 text-[13px] leading-relaxed text-ink-soft">
              Click Install and the hub connects over SSH, uploads the node (one file, nothing else needed), sets it up as a user service, and waits for it to connect.
            </p>

            <.hub_status hub={@hub} self_machine={@self_machine} built={@built} />

            <div
              :if={@tailnet == :loading}
              class="mt-4 flex items-center gap-2 text-sm text-ink-faint"
            >
              <.spinner /> Looking at your tailnet...
            </div>

            <div
              :if={match?({:error, _}, @tailnet)}
              class="mt-4 rounded-xl bg-sunken px-4 py-3 text-sm text-ink-soft"
            >
              {elem(@tailnet, 1)}. You can still add machines with the command below.
            </div>

            <form
              :if={match?({:ok, _}, @tailnet)}
              id="ssh-user-form"
              phx-change="ssh_user"
              phx-auto-recover="ignore"
              class="mt-4 flex flex-wrap items-center gap-2 text-[12.5px] text-ink-soft"
            >
              <label for="ssh-user">SSH as</label>
              <input
                id="ssh-user"
                name="ssh_user"
                value={@ssh_user}
                placeholder={@default_ssh_user || "your SSH default"}
                phx-debounce="300"
                class="h-8 w-44 rounded-lg border border-line bg-surface px-2.5 font-mono text-[12px] text-ink outline-none transition placeholder:text-ink-faint focus:border-accent/70"
              />
              <span class="text-ink-faint">Tailscale SSH (or your keys) must let the hub log in.</span>
            </form>

            <div
              :if={match?({:ok, _}, @tailnet)}
              class="mt-3 divide-y divide-line overflow-hidden rounded-xl border border-line bg-surface shadow-xs"
            >
              <div :if={@self_machine} class="flex items-center gap-3 px-4 py-3 text-sm">
                <.dot status={:ok} />
                <span class="font-mono">{@self_machine.name}</span>
                <span class="text-[12px] text-ink-faint">this hub</span>
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
          </section>

          <section class="mt-10">
            <h2 class="text-[11px] font-semibold tracking-wider text-ink-faint uppercase">
              Any other machine
            </h2>
            <p class="mt-1.5 text-[13px] leading-relaxed text-ink-soft">
              Name the node, then run its command on the machine (or put it in a VPS's cloud-init). It downloads the right build from this hub and sets up a user service.
            </p>
            <.form
              for={@manual_form}
              id="manual-key-form"
              phx-submit="manual_key"
              class="mt-3 flex flex-wrap items-center gap-2"
            >
              <input
                id="manual-node-id"
                name={@manual_form[:node_id].name}
                value={@manual_form[:node_id].value}
                placeholder="node name, e.g. vps-1"
                autocomplete="off"
                class="h-8 w-52 rounded-lg border border-line bg-surface px-2.5 font-mono text-[12px] text-ink outline-none transition placeholder:text-ink-faint focus:border-accent/70"
              />
              <.button id="make-install-command" size="sm" type="submit">Make its command</.button>
            </.form>
            <div :if={@manual} class="group relative mt-3">
              <pre
                id="install-command"
                class="overflow-x-auto rounded-xl border border-line bg-sunken p-3.5 pr-12 font-mono text-[12.5px] leading-relaxed select-all"
              >curl -fsSL {@manual_base}/node/install.sh | PHOTON_NODE_ID={@manual.node_id} PHOTON_NODE_TOKEN={@manual.key} sh</pre>
              <button
                id="copy-install"
                phx-hook=".Copy"
                data-target="install-command"
                class="absolute top-2.5 right-2.5 rounded-md border border-line bg-surface p-1.5 text-ink-faint shadow-xs transition hover:text-ink"
                title="Copy"
              >
                <.icon name="hero-clipboard-document" class="size-4" />
              </button>
            </div>
            <p class="mt-2 text-[12px] leading-relaxed text-ink-faint">
              The command carries a key for that node alone, which the hub ties to the first machine that connects with it. It isn't shown again, and making another replaces it.
              Remove a node with <code class="font-mono">curl -fsSL {@manual_base}/node/install.sh | PHOTON_ACTION=uninstall sh</code>.
            </p>
          </section>
        </div>
      </div>
    </Layouts.app>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Copy">
      export default {
        mounted() {
          this.el.addEventListener("click", () => {
            const text = document.getElementById(this.el.dataset.target).innerText
            navigator.clipboard.writeText(text).then(() => {
              this.el.classList.add("text-ok")
              setTimeout(() => this.el.classList.remove("text-ok"), 1200)
            })
          })
        }
      }
    </script>
    """
  end

  attr :hub, :any, required: true
  attr :self_machine, :any, required: true
  attr :built, :list, required: true

  defp hub_status(assigns) do
    ~H"""
    <p :if={match?({:ok, _}, @hub)} class="mt-3 text-[12px] text-ink-faint">
      Nodes will connect to <code class="font-mono">{Photon.Hub.node_socket_url(elem(@hub, 1))}</code>
    </p>
    <div
      :if={@hub == {:error, :loopback}}
      class="mt-3 rounded-xl bg-warn-soft px-4 py-3 text-[12.5px] leading-relaxed text-ink"
    >
      The hub only listens on this machine, so nodes elsewhere can't reach it. Restart it on its tailnet address
      (<code class="font-mono">PHOTON_BIND={(@self_machine && @self_machine.ip) || "0.0.0.0"}</code>), or set
      <code class="font-mono">PHOTON_PUBLIC_URL</code>
      if it's behind <code class="font-mono">tailscale serve</code>.
    </div>
    <div
      :if={@hub == {:error, :no_address}}
      class="mt-3 rounded-xl bg-warn-soft px-4 py-3 text-[12.5px] text-ink"
    >
      The hub isn't on a tailnet, so set <code class="font-mono">PHOTON_PUBLIC_URL</code>
      to the URL nodes should use.
    </div>
    <div :if={@built == []} class="mt-3 rounded-xl bg-warn-soft px-4 py-3 text-[12.5px] text-ink">
      No node builds are on this hub yet. Build them with
      <code class="font-mono">mix photon.package</code>
      (the Docker image includes them).
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
    <div id={"machine-#{@machine.name}"} class="px-4 py-3">
      <div class="flex flex-wrap items-center gap-x-3 gap-y-1.5 text-sm">
        <.dot status={if(@machine.online, do: :ok, else: :off)} />
        <span class={["font-mono", !@machine.online && "text-ink-faint"]}>{@machine.name}</span>
        <span class="rounded bg-sunken px-1.5 py-0.5 text-[11px] text-ink-soft">{@machine.os}</span>
        <span :if={@machine.tailscale_ssh} class="text-[11px] text-ink-faint">Tailscale SSH</span>
        <span :if={@node? and !@outdated?} class="flex items-center gap-1 text-[11px] text-ok">
          <.icon name="hero-check-circle-micro" class="size-3.5" /> connected
        </span>
        <span :if={@outdated?} class="flex items-center gap-1 text-[11px] text-warn">
          <.icon name="hero-arrow-up-circle-micro" class="size-3.5" /> update available
        </span>
        <span class="flex-1" />
        <span :if={!@machine.installable} class="text-[11px] text-ink-faint">not supported</span>
        <span :if={@machine.installable and !@machine.online} class="text-[11px] text-ink-faint">offline</span>
        <span :if={@busy} class="text-ink-faint"><.spinner /></span>
        <div :if={@machine.installable and @machine.online} class="flex gap-1.5">
          <.button
            id={"install-#{@machine.name}"}
            size="sm"
            variant="primary"
            phx-click="provision"
            phx-value-machine={@machine.name}
            phx-value-action="install"
            disabled={@busy or !@can_install}
          >
            {if(@node?, do: "Update", else: "Install")}
          </.button>
          <.button
            :if={@node?}
            id={"uninstall-#{@machine.name}"}
            size="sm"
            variant="danger"
            phx-click="provision"
            phx-value-machine={@machine.name}
            phx-value-action="uninstall"
            disabled={@busy}
            data-confirm={"Remove the node from #{@machine.name}? Its sessions stay here, read-only."}
          >
            Uninstall
          </.button>
        </div>
      </div>
      <pre
        :if={@job}
        class={[
          "mt-2.5 rounded-lg px-3 py-2 font-mono text-[11.5px] leading-relaxed whitespace-pre-wrap break-all",
          @job.status == :error && "bg-bad-soft text-ink",
          @job.status == :ok && "bg-ok-soft text-ink-soft",
          @job.status == :running && "bg-sunken text-ink-soft"
        ]}
      >{@job.log |> Enum.take(12) |> Enum.reverse() |> Enum.join("\n")}</pre>
    </div>
    """
  end
end
