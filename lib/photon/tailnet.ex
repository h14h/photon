defmodule Photon.Tailnet do
  @moduledoc """
  The machines on this hub's tailnet, from `tailscale status --json` on the
  hub machine (override the binary with `PHOTON_TAILSCALE`).
  """

  @installable ~w(linux macOS)

  @doc "Returns `{:ok, %{self: machine, peers: [machine]}}` or `{:error, reason}`."
  def status do
    exe = System.get_env("PHOTON_TAILSCALE") || System.find_executable("tailscale")

    with exe when is_binary(exe) <-
           exe || {:error, "tailscale isn't installed on the hub machine"},
         {out, 0} <- System.cmd(exe, ["status", "--json"], stderr_to_stdout: true),
         {:ok, json} <- Jason.decode(out) do
      {:ok, parse(json)}
    else
      {:error, %Jason.DecodeError{}} -> {:error, "couldn't read tailscale status"}
      {:error, reason} -> {:error, reason}
      {out, _status} -> {:error, "tailscale status failed: #{String.trim(out)}"}
    end
  end

  @doc """
  Whether `ip` belongs to a peer on the hub's tailnet, per `tailscale whois`.
  Answers are cached for a minute.
  """
  def peer?(ip) when is_tuple(ip) do
    key = {:peer, ip}
    now = System.monotonic_time(:second)

    case :ets.lookup(__MODULE__, key) do
      [{^key, answer, at}] when now - at < 60 ->
        answer

      _ ->
        answer = whois?(ip)
        :ets.insert(__MODULE__, {key, answer, now})
        answer
    end
  end

  defp whois?(ip) do
    exe = System.get_env("PHOTON_TAILSCALE") || System.find_executable("tailscale")
    address = ip |> :inet.ntoa() |> to_string()
    exe != nil and match?({_, 0}, System.cmd(exe, ["whois", address], stderr_to_stdout: true))
  end

  @doc "The hub's own tailnet name and addresses, cached for a minute."
  def own_names do
    key = :own_names
    now = System.monotonic_time(:second)

    case :ets.lookup(__MODULE__, key) do
      [{^key, names, at}] when now - at < 60 ->
        names

      _ ->
        names =
          case status() do
            {:ok, %{self: self}} -> Enum.reject([self.dns, self.ip], &(&1 in [nil, ""]))
            _ -> []
          end

        :ets.insert(__MODULE__, {key, names, now})
        names
    end
  end

  @doc false
  def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_cache, []}}

  @doc false
  # A public ETS table for the whois cache, owned by a process that just waits.
  def start_cache do
    pid =
      spawn_link(fn ->
        :ets.new(__MODULE__, [:named_table, :public, :set])
        Process.sleep(:infinity)
      end)

    {:ok, pid}
  end

  @doc false
  def parse(json) do
    peers =
      (json["Peer"] || %{})
      |> Map.values()
      |> Enum.map(&machine/1)
      |> Enum.sort_by(&{!&1.online, !&1.installable, &1.name})

    %{self: machine(json["Self"] || %{}), peers: peers}
  end

  defp machine(peer) do
    dns = String.trim_trailing(peer["DNSName"] || "", ".")
    # iOS devices report "localhost" as their HostName, so name machines by DNS.
    name = dns |> String.split(".", parts: 2) |> hd()
    name = if name == "", do: peer["HostName"] || "?", else: name

    %{
      name: name,
      dns: dns,
      hostname: peer["HostName"],
      os: peer["OS"],
      ip: List.first(peer["TailscaleIPs"] || []),
      online: peer["Online"] == true,
      tailscale_ssh: (peer["sshHostKeys"] || []) != [],
      tags: peer["Tags"] || [],
      installable: peer["OS"] in @installable
    }
  end
end
