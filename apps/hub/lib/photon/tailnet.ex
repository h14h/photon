defmodule Photon.Tailnet do
  @moduledoc """
  The machines on this hub's tailnet, from `tailscale status --json` on the
  hub machine (override the binary with `PHOTON_TAILSCALE`).

  `peer?/1` and `own_names/0` cache their answers for a minute in a public
  ETS table. This module's process (one, started by `Photon.Application`)
  exists only to own that table, so it lives as long as the hub does; it
  handles no messages. Lookups and inserts go straight to the table from
  the caller, and on a miss the caller runs `tailscale` itself, so a burst
  of misses for the same address can each run it once before the first
  answer is cached.

  `parse/1` and `fresh?/2` are pure.
  """

  use Boundary, deps: []

  use GenServer

  @installable ~w(linux macOS)
  @cache_seconds 60

  @type machine :: %{
          name: String.t(),
          dns: String.t(),
          hostname: String.t() | nil,
          os: String.t() | nil,
          ip: String.t() | nil,
          online: boolean(),
          tailscale_ssh: boolean(),
          tags: [String.t()],
          installable: boolean()
        }

  @doc false
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    __MODULE__ = :ets.new(__MODULE__, [:named_table, :public, :set])
    {:ok, nil}
  end

  @doc "Returns `{:ok, %{self: machine, peers: [machine]}}` or `{:error, reason}`."
  @spec status() :: {:ok, %{self: machine(), peers: [machine()]}} | {:error, String.t()}
  def status do
    with exe when is_binary(exe) <-
           executable() || {:error, "tailscale isn't installed on the hub machine"},
         # Stdout only: the CLI warns on stderr when its version differs from
         # tailscaled's, which would corrupt the JSON.
         {out, 0} <- System.cmd(exe, ["status", "--json"]),
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
  @spec peer?(:inet.ip_address()) :: boolean()
  def peer?(ip) when is_tuple(ip), do: cached({:peer, ip}, fn -> whois?(ip) end)

  defp whois?(ip) do
    exe = executable()
    address = ip |> :inet.ntoa() |> to_string()
    exe != nil and match?({_, 0}, System.cmd(exe, ["whois", address], stderr_to_stdout: true))
  end

  @doc "The hub's own tailnet name and addresses, cached for a minute."
  @spec own_names() :: [String.t()]
  def own_names, do: cached(:own_names, fn -> names(status()) end)

  @doc false
  # The hub's DNS name and address from a `status/0` result, blanks dropped.
  @spec names({:ok, map()} | {:error, term()}) :: [String.t()]
  def names({:ok, %{self: self}}), do: Enum.reject([self.dns, self.ip], &(&1 in [nil, ""]))
  def names(_status), do: []

  defp cached(key, compute) do
    now = System.monotonic_time(:second)

    case :ets.lookup(__MODULE__, key) do
      [{^key, answer, at}] ->
        if fresh?(at, now), do: answer, else: store(key, compute.(), now)

      _ ->
        store(key, compute.(), now)
    end
  end

  defp store(key, answer, now) do
    :ets.insert(__MODULE__, {key, answer, now})
    answer
  end

  @doc false
  # Whether an answer cached at `at` (monotonic seconds) is still good at `now`.
  @spec fresh?(integer(), integer()) :: boolean()
  def fresh?(at, now), do: now - at < @cache_seconds

  defp executable, do: System.get_env("PHOTON_TAILSCALE") || System.find_executable("tailscale")

  @doc false
  @spec parse(map()) :: %{self: machine(), peers: [machine()]}
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
