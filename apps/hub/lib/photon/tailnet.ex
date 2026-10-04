defmodule Photon.Tailnet do
  @moduledoc """
  The machines on this hub's tailnet, from `tailscale status --json` on the
  hub machine (override the binary with `PHOTON_TAILSCALE`).

  `whois/1`, `owner_login/0` and `own_names/0` cache their answers for a
  minute in a public ETS table. This module's process (one, started by `Photon.Application`)
  exists only to own that table, so it lives as long as the hub does; it
  handles no messages. Lookups and inserts go straight to the table from
  the caller, and on a miss the caller runs `tailscale` itself, so a burst
  of misses for the same address can each run it once before the first
  answer is cached.

  `parse/1`, `parse_whois/1` and `fresh?/2` are pure.
  """

  use Boundary, deps: []

  use GenServer

  @installable ~w(linux macOS)
  @cache_seconds 60

  @type machine :: %{
          id: String.t() | nil,
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

  @typedoc "The hub machine, its peers, and the login of the user who owns the hub machine."
  @type tailnet :: %{self: machine(), peers: [machine()], owner: String.t() | nil}

  @typedoc """
  Who is at the other end of a connection from a tailnet address: the
  device (its stable ID and name), its tags, and the login of the user it
  belongs to (nil for a tagged device, which belongs to no user).
  """
  @type identity :: %{
          device: String.t(),
          device_name: String.t(),
          login: String.t() | nil,
          tags: [String.t()]
        }

  @doc false
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    __MODULE__ = :ets.new(__MODULE__, [:named_table, :public, :set])
    {:ok, nil}
  end

  @doc "Returns `{:ok, tailnet}` or `{:error, reason}`."
  @spec status() :: {:ok, tailnet()} | {:error, String.t()}
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
  Who `ip` is on the hub's tailnet, per `tailscale whois`: `{:ok, identity}`,
  or `:error` when it isn't a peer (or tailscale isn't on the hub machine).
  The device is decided by Tailscale's own keys, not by the address range.
  Answers are cached for a minute.
  """
  @spec whois(:inet.ip_address()) :: {:ok, identity()} | :error
  def whois(ip) when is_tuple(ip), do: cached({:whois, ip}, fn -> run_whois(ip) end)

  defp run_whois(ip) do
    with exe when is_binary(exe) <- executable(),
         # Stdout only, as in status/0.
         {out, 0} <- System.cmd(exe, ["whois", "--json", ip |> :inet.ntoa() |> to_string()]),
         {:ok, json} <- Jason.decode(out) do
      parse_whois(json)
    else
      _ -> :error
    end
  end

  @doc """
  The login of the user who owns the hub machine (nil if it's tagged, or
  tailscale can't say), cached for a minute.
  """
  @spec owner_login() :: String.t() | nil
  def owner_login do
    cached(:owner, fn ->
      case status() do
        {:ok, %{owner: owner}} -> owner
        {:error, _reason} -> nil
      end
    end)
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

  # Tests set `find_tailscale: false`, so only a stand-in they name runs.
  defp executable do
    System.get_env("PHOTON_TAILSCALE") ||
      (Application.get_env(:photon, :find_tailscale, true) && System.find_executable("tailscale")) ||
      nil
  end

  @doc false
  @spec parse(map()) :: tailnet()
  def parse(json) do
    peers =
      (json["Peer"] || %{})
      |> Map.values()
      |> Enum.map(&machine/1)
      |> Enum.sort_by(&{!&1.online, !&1.installable, &1.name})

    %{self: machine(json["Self"] || %{}), peers: peers, owner: owner(json)}
  end

  # A tagged machine belongs to no user.
  defp owner(%{"Self" => %{"UserID" => user} = self} = json) do
    if (self["Tags"] || []) == [], do: login(json["User"], user)
  end

  defp owner(_json), do: nil

  # A user's login, from status's table of users by ID.
  defp login(%{} = users, user), do: get_in(users, [to_string(user), "LoginName"])
  defp login(_users, _user), do: nil

  @doc false
  # A `tailscale whois --json` answer as an identity; `:error` without a device.
  @spec parse_whois(term()) :: {:ok, identity()} | :error
  def parse_whois(%{"Node" => %{"StableID" => device} = node} = json)
      when is_binary(device) and device != "" do
    tags = node["Tags"] || []

    {:ok,
     %{
       device: device,
       device_name: node["ComputedName"] || node_name(node["Name"]),
       login: if(tags == [], do: get_in(json, ["UserProfile", "LoginName"])),
       tags: tags
     }}
  end

  def parse_whois(_json), do: :error

  defp node_name(name) when is_binary(name), do: name |> String.split(".", parts: 2) |> hd()
  defp node_name(_name), do: "?"

  defp machine(peer) do
    dns = String.trim_trailing(peer["DNSName"] || "", ".")
    # iOS devices report "localhost" as their HostName, so name machines by DNS.
    name = dns |> String.split(".", parts: 2) |> hd()
    name = if name == "", do: peer["HostName"] || "?", else: name

    %{
      # Tailscale's stable device ID, as `whois/1` reports it.
      id: peer["ID"],
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
