defmodule Photon.Provision do
  @moduledoc """
  Installs, updates and removes nodes on other machines over SSH.

  Uses the hub machine's own `ssh` (override with `PHOTON_SSH`), so your keys,
  agent, `~/.ssh/config` and Tailscale SSH all apply. It runs non-interactively
  (`BatchMode`) and trusts a host key on first use (`accept-new`). An install:

    1. probes the machine's OS and CPU,
    2. streams up the matching binary from `Photon.NodeDist`,
    3. runs the install script (`priv/node/install.sh.eex`) with a new key
       for the node (`Photon.NodeKeys.issue/1`) on stdin, never on a
       command line,
    4. waits for the node to connect.

  So every install and update gives the node a fresh key and revokes its
  old one; an update that fails after that leaves the node offline until
  it's run again. Removing a node revokes its key.

  One job runs per machine at a time. Job state is broadcast on `topic/0` as
  `{:provision, jobs}`, so every open tab sees progress.

  ## Processes

  This module's server (one, named after it) keeps the job table
  (`Photon.Provision.Jobs`); its API is `run/2` and `jobs/0`, both calls.
  Each job runs as a task under `Photon.ProvisionTasks`, started with
  `async_nolink` and monitored: a job reports progress to the server as it
  goes (plain sends, a line at a time), and a job that dies without
  reporting its end is marked failed, so its machine doesn't stay busy.
  A server restart loses the table; jobs still running then report to
  nobody and finish on their own. The SSH steps and the scripts they send
  are `Photon.Provision.Script`.
  """

  use Boundary,
    deps: [Photon.Events, Photon.InstallScript, Photon.NodeDist, Photon.NodeKeys, Photon.Nodes]

  use GenServer

  alias Photon.{Events, NodeDist, Nodes}
  alias Photon.Provision.{Jobs, Script}

  @topic "provision"
  @connect_timeout :timer.seconds(60)

  defstruct jobs: %{}, tasks: %{}

  @typedoc "The job table, and each running job's task monitor to its machine."
  @type t :: %__MODULE__{jobs: Jobs.t(), tasks: %{reference() => String.t()}}

  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribes to `{:provision, jobs}`."
  @spec subscribe() :: :ok
  def subscribe, do: Events.subscribe(@topic)

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Current jobs, keyed by machine name."
  @spec jobs() :: Jobs.t()
  def jobs, do: GenServer.call(__MODULE__, :jobs)

  @doc """
  Starts a job. `action` is `:install` (also updates) or `:uninstall`.

  Options: `:machine` (tailnet name), `:host` (what to ssh to), `:ssh_user`,
  `:node_id`, `:base_url` (how the node reaches the hub), `:env` (extra
  variables for the install script).
  """
  @spec run(:install | :uninstall, keyword()) :: :ok | {:error, String.t()}
  def run(action, opts) when action in [:install, :uninstall] do
    GenServer.call(__MODULE__, {:run, action, Map.new(opts)})
  end

  @doc "The SSH user the hub falls back to (`PHOTON_SSH_USER`), for the form's placeholder."
  @spec default_ssh_user() :: String.t() | nil
  def default_ssh_user, do: System.get_env("PHOTON_SSH_USER")

  @impl true
  def init(_), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call(:jobs, _from, state), do: {:reply, state.jobs, state}

  def handle_call({:run, action, opts}, _from, state) do
    with :ok <- Jobs.validate(opts), :ok <- Jobs.idle(state.jobs, opts.machine) do
      task = start_job(action, opts)
      jobs = Map.put(state.jobs, opts.machine, Jobs.new(action, opts, DateTime.utc_now()))
      broadcast(jobs)
      {:reply, :ok, %{state | jobs: jobs, tasks: Map.put(state.tasks, task.ref, opts.machine)}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:job, machine, event}, state) do
    {:noreply, update_job(state, machine, &Jobs.apply_event(&1, event))}
  end

  # The job's task returned; it reported its end before that.
  def handle_info({ref, _result}, state) when is_map_key(state.tasks, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | tasks: Map.delete(state.tasks, ref)}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.tasks, ref) do
    {machine, tasks} = Map.pop(state.tasks, ref)
    {:noreply, update_job(%{state | tasks: tasks}, machine, &Jobs.task_down(&1, reason))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp update_job(state, machine, fun) do
    jobs = Map.update!(state.jobs, machine, fun)
    broadcast(jobs)
    %{state | jobs: jobs}
  end

  defp start_job(action, opts) do
    server = self()
    report = fn event -> send(server, {:job, opts.machine, event}) end
    Task.Supervisor.async_nolink(Photon.ProvisionTasks, fn -> job(action, opts, report) end)
  end

  defp broadcast(jobs), do: Events.broadcast(@topic, {:provision, jobs})

  ## The job itself, run in a task.

  # Runs in the task: always ends with a {:done, ...} report.
  defp job(action, opts, report) do
    result =
      try do
        steps(action, opts, report)
      rescue
        e -> {:error, Exception.message(e)}
      end

    case result do
      {:ok, message} -> report.({:done, :ok, message})
      {:error, message} -> report.({:done, :error, "Failed: " <> message})
    end
  end

  defp steps(:install, opts, report) do
    log = fn line -> report.({:log, line}) end
    log.("Connecting to #{target(opts)} over SSH")

    with {:ok, probe} <- ssh(opts, "sh -s", {:text, Script.probe()}, log),
         {:ok, platform} <- platform(probe),
         {:ok, binary} <- binary(platform),
         :ok <- upload(opts, probe, platform, binary, log),
         {:ok, since} <- install(opts, log) do
      log.("Waiting for #{opts.node_id} to connect to the hub")
      wait_for_node(opts.node_id, since)
    end
  end

  defp steps(:uninstall, opts, report) do
    log = fn line -> report.({:log, line}) end
    log.("Connecting to #{target(opts)} over SSH")

    with {:ok, out} <- ssh(opts, "sh -s", {:text, Script.uninstall_input(opts.base_url)}, log),
         true <- out =~ "PHOTON_UNINSTALL_OK" || {:error, "the uninstaller didn't finish"} do
      :ok = Photon.NodeKeys.revoke(opts.node_id)
      {:ok, "Removed the node from #{opts.machine}. Its sessions stay here, read-only."}
    end
  end

  defp upload(opts, probe, platform, binary, log) do
    log.(Script.describe(platform, probe))
    log.("Uploading photon-node-#{platform} (#{div(File.stat!(binary).size, 1_048_576)} MB)")

    case ssh(opts, Script.upload(), {:file, binary}, log) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # The new node may connect before the installer even returns, so the
  # wait counts connections from just before it runs.
  defp install(opts, log) do
    log.("Installing")
    since = DateTime.utc_now()
    {:ok, key} = Photon.NodeKeys.issue(opts.node_id)
    input = Script.install_input(opts, key)

    with {:ok, out} <- ssh(opts, "sh -s", {:text, input}, log),
         true <- out =~ "PHOTON_INSTALL_OK" || {:error, "the installer didn't finish"} do
      {:ok, since}
    end
  end

  defp platform(probe) do
    case NodeDist.target(probe["os"], probe["arch"]) do
      {:ok, target} -> {:ok, target}
      :error -> {:error, "unsupported platform #{probe["os"]} #{probe["arch"]}"}
    end
  end

  defp binary(target) do
    case NodeDist.binary(target) do
      {:ok, path} ->
        {:ok, path}

      {:error, _} ->
        {:error,
         "no #{target} build on the hub. Build it with: mix photon.package --targets #{NodeDist.package_target(target)}"}
    end
  end

  # Waits in the job's task (not in the server) for the node to join.
  defp wait_for_node(node_id, since) do
    Nodes.subscribe()
    deadline = System.monotonic_time(:millisecond) + @connect_timeout
    await_node(node_id, since, deadline)
  end

  defp await_node(node_id, since, deadline) do
    case Nodes.get(node_id) do
      %{"connected_at" => at} = node ->
        if DateTime.compare(at, since) != :lt do
          {:ok, "#{node_id} is connected (photon-node #{node["version"]}, #{node["platform"]})"}
        else
          wait_more(node_id, since, deadline)
        end

      nil ->
        wait_more(node_id, since, deadline)
    end
  end

  defp wait_more(node_id, since, deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      {:error,
       "installed, but #{node_id} hasn't connected. Check that it can reach the hub, and its log in ~/.local/share/photon-node/node.log or `journalctl --user -u photon-node`."}
    else
      receive do
        :nodes_changed -> await_node(node_id, since, deadline)
      after
        min(left, 1_000) -> await_node(node_id, since, deadline)
      end
    end
  end

  ## SSH plumbing

  # "SSH as" in the panel, else PHOTON_SSH_USER, else ssh's own default.
  defp target(%{host: host} = opts) do
    Script.target(
      host,
      (opts[:ssh_user] not in [nil, ""] && opts[:ssh_user]) || default_ssh_user()
    )
  end

  # Runs `remote` on the machine with `input` on stdin, streaming its output
  # lines to `log`. A Port can't signal end-of-input, so stdin comes from a file.
  defp ssh(opts, remote, input, log) do
    exe =
      System.get_env("PHOTON_SSH") || System.find_executable("ssh") ||
        raise "ssh isn't installed on the hub"

    {stdin, cleanup} = stdin_file(input)

    args =
      Script.ssh_args(target(opts), remote, control_dir(), System.get_env("PHOTON_SSH_PROXY"))

    try do
      {lines, status} =
        System.cmd(
          "sh",
          ["-c", ~s(f=$1; shift; exec "$@" < "$f"), "photon-ssh", stdin, exe | args],
          stderr_to_stdout: true,
          into: %__MODULE__.Lines{log: log}
        )

      output = Enum.join(lines.all, "\n")

      case status do
        0 -> {:ok, Script.parse_probe(output)}
        255 -> {:error, "SSH to #{target(opts)} failed: #{Script.ssh_reason(output)}"}
        n -> {:error, "exited with #{n}: #{Script.last_line(output)}"}
      end
    after
      cleanup.()
    end
  end

  @doc false
  @spec ssh_reason(String.t()) :: String.t()
  defdelegate ssh_reason(output), to: Script

  defp stdin_file({:file, path}), do: {path, fn -> :ok end}

  defp stdin_file({:text, text}) do
    path = Path.join(control_dir(), "stdin-#{System.unique_integer([:positive])}")
    File.write!(path, text)
    File.chmod!(path, 0o600)
    {path, fn -> File.rm(path) end}
  end

  # SSH control sockets need a short path, so this lives directly under /tmp.
  defp control_dir do
    dir = Path.join(System.tmp_dir!(), "photon-ssh-#{System.get_env("USER", "hub")}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    dir
  end
end
