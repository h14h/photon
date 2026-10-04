defmodule Photon.Provision.Script do
  @moduledoc """
  What `Photon.Provision` sends over SSH and how it reads the answers, as
  pure functions: the probe, the upload command, the installer's input
  (environment exports, then the install script), the `ssh` arguments, and
  explanations of SSH failures.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [Photon.InstallScript]

  alias Photon.InstallScript

  @bin_dir "$HOME/.local/share/photon-node/bin"

  @doc "Prints the machine's OS, CPU, user and installed node, as `key=value` lines."
  @spec probe() :: String.t()
  def probe do
    """
    echo "os=$(uname -s)"
    echo "arch=$(uname -m)"
    echo "user=$(id -un)"
    b="#{@bin_dir}/photon-node"
    if [ -x "$b" ]; then echo "installed=photon-node $("$b" --version 2>/dev/null)"; fi
    """
  end

  @doc """
  Probe output as a map of `os`, `arch`, `user` and `installed`; output with
  fewer than three of those passes through as text.
  """
  @spec parse_probe(String.t()) :: map() | String.t()
  def parse_probe(output) do
    pairs =
      for line <- String.split(output, "\n"),
          [k, v] <- [String.split(line, "=", parts: 2)],
          k in ~w(os arch user installed),
          into: %{},
          do: {k, v}

    if map_size(pairs) >= 3, do: pairs, else: output
  end

  @doc "The remote command that receives the binary on stdin."
  @spec upload() :: String.t()
  def upload, do: ~s(umask 077; mkdir -p "#{@bin_dir}" && cat > "#{@bin_dir}/photon-node.upload")

  @doc "What the probe says about the machine, for the job's log."
  @spec describe(String.t(), map()) :: String.t()
  def describe(platform, probe) do
    "#{platform}, user #{probe["user"]}" <>
      if(probe["installed"], do: ", has #{probe["installed"]}", else: "")
  end

  @doc """
  The installer's stdin: the node's settings as exports (the token among
  them, so it never appears on a command line), then the install script.
  """
  @spec install_input(map(), String.t()) :: String.t()
  def install_input(opts, token) do
    env =
      Map.merge(opts[:env] || %{}, %{
        "PHOTON_NODE_TOKEN" => token,
        "PHOTON_NODE_ID" => opts.node_id,
        "PHOTON_SERVER" => InstallScript.socket_url(opts.base_url)
      })

    # PHOTON_BINARY refers to the remote $HOME, so it's exported unquoted.
    exports(env) <>
      ~s(PHOTON_BINARY="#{@bin_dir}/photon-node.upload"; export PHOTON_BINARY\n) <>
      InstallScript.render(opts.base_url)
  end

  @doc "The uninstaller's stdin."
  @spec uninstall_input(String.t()) :: String.t()
  def uninstall_input(base_url),
    do: exports(%{"PHOTON_ACTION" => "uninstall"}) <> InstallScript.render(base_url)

  defp exports(env) do
    Enum.map_join(env, "", fn {k, v} -> "#{k}=#{sh_quote(v)}; export #{k}\n" end)
  end

  defp sh_quote(value), do: "'" <> String.replace(value, "'", ~S('\'')) <> "'"

  @doc """
  The `ssh` arguments that run `remote` on `target`: non-interactive,
  trusting a host key on first use, sharing a control connection under
  `control_dir`, and through `proxy` (a ProxyCommand) when one is set.
  """
  @spec ssh_args(String.t(), String.t(), String.t(), String.t() | nil) :: [String.t()]
  def ssh_args(target, remote, control_dir, proxy) do
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
      "ControlPath=#{control_dir}/%C",
      "-o",
      "ControlPersist=60",
      target,
      remote
    ]

    # In a container, the tailnet is reached through tailscaled (userspace
    # networking), so SSH goes via `tailscale nc`.
    if proxy in [nil, ""], do: args, else: ["-o", "ProxyCommand=#{proxy}" | args]
  end

  @doc "`user@host`, or just the host when there's no user to name."
  @spec target(String.t(), String.t() | nil | false) :: String.t()
  def target(host, user) when user not in [nil, false, ""], do: "#{user}@#{host}"
  def target(host, _user), do: host

  # ssh's last words are often generic ("Connection closed"), so prefer the
  # line that says why, and suggest the fix for the usual one.
  @ssh_causes ~r/tailscale:|Permission denied|Could not resolve|Connection refused|Host key verification failed|timed out|No route to host/

  @doc "Why an SSH connection failed, from its output, with a fix for the usual cause."
  @spec ssh_reason(String.t()) :: String.t()
  def ssh_reason(output) do
    lines = String.split(output, "\n", trim: true)
    reason = Enum.find(lines, &(&1 =~ @ssh_causes)) || List.last(lines) || "no output"

    if reason =~ ~r/permit you to SSH as user|Permission denied/,
      do:
        reason <> ". Set \"SSH as\" (or PHOTON_SSH_USER on the hub) to your user on that machine.",
      else: reason
  end

  @doc "The last line of a command's output."
  @spec last_line(String.t()) :: String.t()
  def last_line(output) do
    output |> String.split("\n", trim: true) |> List.last() || "no output"
  end
end
