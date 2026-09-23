defmodule Photon.Provision do
  @moduledoc """
  Installs, updates and removes nodes on other machines over SSH.

  Uses the hub machine's own `ssh` (override with `PHOTON_SSH`), so your keys,
  agent, `~/.ssh/config` and Tailscale SSH all apply. It runs non-interactively
  (`BatchMode`) and trusts a host key on first use (`accept-new`). An install:

    1. probes the machine's OS and CPU,
    2. streams up the matching binary from `Photon.NodeDist`,
    3. runs the install script (`priv/node/install.sh.eex`) with the token on
       stdin, never on a command line,
    4. waits for the node to connect.

  One job runs per machine at a time. Job state is broadcast on `topic/0` as
  `{:provision, jobs}`, so every open tab sees progress.
  """

  use GenServer

  alias Photon.{NodeDist, Nodes}

  @topic "provision"
  @connect_timeout :timer.seconds(60)

  def topic, do: @topic

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Current jobs, keyed by machine name."
  def jobs, do: GenServer.call(__MODULE__, :jobs)

  @doc """
  Starts a job. `action` is `:install` (also updates) or `:uninstall`.

  Options: `:machine` (tailnet name), `:host` (what to ssh to), `:ssh_user`,
  `:node_id`, `:base_url` (how the node reaches the hub), `:env` (extra
  variables for the install script).
  """
  def run(action, opts) when action in [:install, :uninstall] do
    GenServer.call(__MODULE__, {:run, action, Map.new(opts)})
  end

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call(:jobs, _from, jobs), do: {:reply, jobs, jobs}

  def handle_call({:run, action, opts}, _from, jobs) do
    with :ok <- validate(opts), :ok <- idle(jobs, opts.machine) do
      server = self()
      report = fn event -> send(server, {:job, opts.machine, event}) end

      {:ok, _} =
        Task.Supervisor.start_child(Photon.ProvisionTasks, fn -> job(action, opts, report) end)

      job = %{
        action: action,
        status: :running,
        log: [],
        node_id: opts[:node_id],
        started_at: DateTime.utc_now()
      }

      jobs = Map.put(jobs, opts.machine, job)
      broadcast(jobs)
      {:reply, :ok, jobs}
    else
      {:error, reason} -> {:reply, {:error, reason}, jobs}
    end
  end

  @impl true
  def handle_info({:job, machine, event}, jobs) do
    jobs =
      Map.update!(jobs, machine, fn job ->
        case event do
          {:log, line} -> %{job | log: Enum.take([line | job.log], 300)}
          {:done, :ok, message} -> %{job | status: :ok, log: [message | job.log]}
          {:done, :error, message} -> %{job | status: :error, log: [message | job.log]}
        end
      end)

    broadcast(jobs)
    {:noreply, jobs}
  end

  defp idle(jobs, machine) do
    if match?(%{status: :running}, jobs[machine]), do: {:error, "already busy"}, else: :ok
  end

  defp broadcast(jobs), do: Phoenix.PubSub.broadcast(Photon.PubSub, @topic, {:provision, jobs})

  defp validate(opts) do
    cond do
      not valid?(opts[:host], ~r/\A[A-Za-z0-9.\-]{1,253}\z/) ->
        {:error, "invalid host"}

      opts[:ssh_user] not in [nil, ""] and
          not valid?(opts[:ssh_user], ~r/\A[A-Za-z_][A-Za-z0-9_.\-]{0,31}\z/) ->
        {:error, "invalid SSH user"}

      opts[:node_id] && not valid?(opts[:node_id], ~r/\A[\w.\-]{1,64}\z/) ->
        {:error, "invalid node name"}

      true ->
        :ok
    end
  end

  defp valid?(value, regex), do: is_binary(value) and value =~ regex

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

  @bin_dir "$HOME/.local/share/photon-node/bin"

  defp steps(:install, opts, report) do
    log = fn line -> report.({:log, line}) end
    log.("Connecting to #{target(opts)} over SSH")

    with {:ok, probe} <- ssh(opts, "sh -s", {:text, probe_script()}, log),
         {:ok, platform} <- platform(probe),
         {:ok, binary} <- binary(platform) do
      log.(
        "#{platform}, user #{probe["user"]}" <>
          if(probe["installed"], do: ", has #{probe["installed"]}", else: "")
      )

      log.("Uploading photon-node-#{platform} (#{div(File.stat!(binary).size, 1_048_576)} MB)")

      upload = ~s(umask 077; mkdir -p "#{@bin_dir}" && cat > "#{@bin_dir}/photon-node.upload")

      with {:ok, _} <- ssh(opts, upload, {:file, binary}, log),
           _ = log.("Installing"),
           # The new node may connect before the installer even returns.
           since = DateTime.utc_now(),
           {:ok, out} <- ssh(opts, "sh -s", {:text, install_input(opts)}, log),
           true <- out =~ "PHOTON_INSTALL_OK" || {:error, "the installer didn't finish"} do
        log.("Waiting for #{opts.node_id} to connect to the hub")
        wait_for_node(opts.node_id, since)
      end
    end
  end

  defp steps(:uninstall, opts, report) do
    log = fn line -> report.({:log, line}) end
    log.("Connecting to #{target(opts)} over SSH")
    input = exports(%{"PHOTON_ACTION" => "uninstall"}) <> NodeDist.install_script(opts.base_url)

    with {:ok, out} <- ssh(opts, "sh -s", {:text, input}, log),
         true <- out =~ "PHOTON_UNINSTALL_OK" || {:error, "the uninstaller didn't finish"} do
      {:ok, "Removed the node from #{opts.machine}. Its sessions stay here, read-only."}
    end
  end

  defp probe_script do
    """
    echo "os=$(uname -s)"
    echo "arch=$(uname -m)"
    echo "user=$(id -un)"
    b="#{@bin_dir}/photon-node"
    if [ -x "$b" ]; then echo "installed=photon-node $("$b" --version 2>/dev/null)"; fi
    """
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

  defp install_input(opts) do
    env =
      Map.merge(opts[:env] || %{}, %{
        "PHOTON_NODE_TOKEN" => Photon.NodeAuth.token(),
        "PHOTON_NODE_ID" => opts.node_id,
        "PHOTON_SERVER" => Photon.Hub.node_socket_url(opts.base_url)
      })

    # PHOTON_BINARY refers to the remote $HOME, so it's exported unquoted.
    exports(env) <>
      ~s(PHOTON_BINARY="#{@bin_dir}/photon-node.upload"; export PHOTON_BINARY\n) <>
      NodeDist.install_script(opts.base_url)
  end

  defp exports(env) do
    Enum.map_join(env, "", fn {k, v} -> "#{k}=#{sh_quote(v)}; export #{k}\n" end)
  end

  defp sh_quote(value), do: "'" <> String.replace(value, "'", ~S('\'')) <> "'"

  defp wait_for_node(node_id, since) do
    Phoenix.PubSub.subscribe(Photon.PubSub, Nodes.topic())
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
    case (opts[:ssh_user] not in [nil, ""] && opts[:ssh_user]) ||
           System.get_env("PHOTON_SSH_USER") do
      user when user not in [nil, false, ""] -> "#{user}@#{host}"
      _ -> host
    end
  end

  # Runs `remote` on the machine with `input` on stdin, streaming its output
  # lines to `log`. A Port can't signal end-of-input, so stdin comes from a file.
  defp ssh(opts, remote, input, log) do
    exe =
      System.get_env("PHOTON_SSH") || System.find_executable("ssh") ||
        raise "ssh isn't installed on the hub"

    {stdin, cleanup} = stdin_file(input)

    args = [
      "-o",
      "BatchMode=yes",
      "-o",
      "ConnectTimeout=15",
      "-o",
      "StrictHostKeyChecking=accept-new",
      "-o",
      "ControlMaster=auto",
      "-o",
      "ControlPath=#{control_dir()}/%C",
      "-o",
      "ControlPersist=60",
      target(opts),
      remote
    ]

    # In a container, the tailnet is reached through tailscaled (userspace
    # networking), so SSH goes via `tailscale nc`.
    args =
      case System.get_env("PHOTON_SSH_PROXY") do
        proxy when proxy not in [nil, ""] -> ["-o", "ProxyCommand=#{proxy}" | args]
        _ -> args
      end

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
        0 -> {:ok, parse_probe(output)}
        255 -> {:error, "SSH to #{target(opts)} failed: #{ssh_reason(output)}"}
        n -> {:error, "exited with #{n}: #{last_line(output)}"}
      end
    after
      cleanup.()
    end
  end

  # Probe output is key=value lines; other output passes through as a string.
  defp parse_probe(output) do
    pairs =
      for line <- String.split(output, "\n"),
          [k, v] <- [String.split(line, "=", parts: 2)],
          k in ~w(os arch user installed),
          into: %{},
          do: {k, v}

    if map_size(pairs) >= 3, do: pairs, else: output
  end

  # ssh's last words are often generic ("Connection closed"), so prefer the
  # line that says why, and suggest the fix for the usual one.
  @ssh_causes ~r/tailscale:|Permission denied|Could not resolve|Connection refused|Host key verification failed|timed out|No route to host/

  @doc false
  def ssh_reason(output) do
    lines = String.split(output, "\n", trim: true)
    reason = Enum.find(lines, &(&1 =~ @ssh_causes)) || List.last(lines) || "no output"

    if reason =~ ~r/permit you to SSH as user|Permission denied/,
      do:
        reason <> ". Set \"SSH as\" (or PHOTON_SSH_USER on the hub) to your user on that machine.",
      else: reason
  end

  defp last_line(output) do
    output |> String.split("\n", trim: true) |> List.last() || "no output"
  end

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
