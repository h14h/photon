defmodule Photon.NodeKeys do
  @moduledoc """
  Each node's own key: what it presents to connect to the hub
  (`PhotonWeb.NodeSocket`). A key works for one node ID only, so a node
  can't connect as another.

  The hub keeps only each key's SHA-256 (`Photon.NodeKeys.Key`). A node
  gets a new key whenever it is installed or updated, replacing the old
  one. Each key has a `generation` from the clock, so a node's generations
  never repeat, not even after a removal, and a connection made with an
  old key can always be told apart. Every change is announced on
  `topic/0`, so a node still connected with an old key is dropped
  (`PhotonWeb.NodeChannel`) and open GUI pages are checked again
  (`PhotonWeb.Auth`).

  On a tailnet, a key is tied to a device (Tailscale's stable device ID);
  a hub without a tailnet leaves keys untied. An install over SSH ties it
  to the machine it installs on before the key exists anywhere. A key made
  for a manual install is tied to the first device that connects with it,
  in one conditional update so two can't both claim it; only one of the
  user's own devices or a tagged one may claim it (`logins:`), and it
  stops working if none has within an hour.

  The tie outlives the key. A new key for the same node keeps it, and a
  removed node leaves its row behind (`revoked_at`, with no usable key). So
  a machine counts as running a node (`node_devices/0`, which `Photon.Auth`
  keeps out of the GUI) from its install, through every update, until the
  user lets it back in with `forget/1`: a removal that failed to stop
  everything on the machine never unlocks the GUI for it.

  The built-in node in the hub's own BEAM (development) gets `local_token/0`
  instead: made at boot, kept in memory, and good only for node `local`
  connecting from the hub machine itself. Its generation is -1, which no
  stored key has, and no other node may be called `local`.
  """

  use Boundary, deps: [Photon.Events, Photon.Repo, Photon.Tailnet, Ecto]

  import Ecto.Query

  alias Photon.{Events, Repo}
  alias Photon.NodeKeys.Key

  @prefix "pnk_"
  @local "local"
  @local_generation -1
  @topic "node_keys"
  @unused_key_lifetime_s 3600

  @typedoc """
  Where a key was presented from: a tailnet device (`Photon.Tailnet.whois/1`),
  `:local` (the hub machine itself), or `:error` (somewhere the tailnet
  can't name).
  """
  @type origin :: {:ok, Photon.Tailnet.identity()} | :local | :error

  @typedoc "A device to tie a key to: its stable ID and name."
  @type device :: %{device: String.t(), device_name: String.t()}

  @doc "PubSub topic carrying `{:node_keys_changed, node_id}`."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribes to `{:node_keys_changed, node_id}`."
  @spec subscribe() :: :ok
  def subscribe, do: Events.subscribe(@topic)

  @doc "The name kept for the built-in node."
  @spec reserved?(String.t()) :: boolean()
  def reserved?(node_id), do: node_id == @local

  @doc """
  Makes `node_id` a new key, replacing (and so revoking) any it had, and
  returns it. With `device:`, the key is tied to that device now;
  otherwise it keeps the node's earlier device (even after a removal), or
  waits an hour for its first.
  """
  @spec issue(String.t(), keyword()) :: {:ok, String.t()}
  def issue(node_id, opts \\ []) do
    if reserved?(node_id), do: raise(ArgumentError, "#{@local} is the built-in node's name")
    key = @prefix <> random(32)
    now = DateTime.utc_now()

    {:ok, _key} =
      Repo.transaction(fn ->
        previous = Repo.get(Key, node_id)
        device = opts[:device] || previous_device(previous)

        Repo.insert!(
          %Key{
            node_id: node_id,
            key_hash: hash(key),
            device: device && device.device,
            device_name: device && device.device_name,
            generation: next_generation(previous),
            expires_at: if(device, do: nil, else: DateTime.add(now, @unused_key_lifetime_s)),
            revoked_at: nil
          },
          on_conflict:
            {:replace,
             [
               :key_hash,
               :device,
               :device_name,
               :generation,
               :expires_at,
               :revoked_at,
               :updated_at
             ]},
          conflict_target: :node_id
        )
      end)

    :ok = announce(node_id)
    {:ok, key}
  end

  defp previous_device(%Key{device: device, device_name: name}) when is_binary(device),
    do: %{device: device, device_name: name}

  defp previous_device(_previous), do: nil

  # From the clock, and always past the node's last one.
  defp next_generation(nil), do: System.os_time(:microsecond)

  defp next_generation(%Key{generation: last}),
    do: max(System.os_time(:microsecond), last + 1)

  @doc """
  Takes `node_id`'s key away, so nothing can connect as it. Its machine
  stays counted as a node, out of the GUI, until `forget/1`.
  """
  @spec revoke(String.t()) :: :ok
  def revoke(node_id) do
    :ok =
      case Repo.get(Key, node_id) do
        nil -> :ok
        key -> tombstone(key)
      end

    announce(node_id)
  end

  defp tombstone(key) do
    changes =
      Ecto.Changeset.change(key,
        # A hash of nothing anyone holds, so no key matches it.
        key_hash: hash(random(32)),
        generation: next_generation(key),
        expires_at: nil,
        revoked_at: DateTime.utc_now()
      )

    _key = Repo.update!(changes)
    :ok
  end

  @doc """
  Lets a removed node's machine open the GUI again, by forgetting the node
  altogether. Refused for a node that still has a key.
  """
  @spec forget(String.t()) :: :ok | {:error, String.t()}
  def forget(node_id) do
    case Key
         |> where([k], k.node_id == ^node_id and not is_nil(k.revoked_at))
         |> Repo.delete_all() do
      {1, _} -> announce(node_id)
      {0, _} -> {:error, "#{node_id} is still a node. Remove it first."}
    end
  end

  @doc "Removed nodes whose machines are still kept out of the GUI, by node ID."
  @spec removed() :: [Key.t()]
  def removed do
    Key |> where([k], not is_nil(k.revoked_at)) |> order_by([k], k.node_id) |> Repo.all()
  end

  @doc """
  The node a key belongs to and the key's generation, checked against where
  it came from (see `check/4`). Options: `require_tailnet: true` refuses
  keys from origins the tailnet can't name; `logins:` limits which tailnet
  devices may claim an untied key (theirs, or tagged ones).
  """
  @spec authenticate(term(), origin(), keyword()) ::
          {:ok, String.t(), integer()} | {:error, String.t()}
  def authenticate(token, origin, opts \\ [])

  def authenticate(token, origin, opts) when is_binary(token) do
    if Plug.Crypto.secure_compare(token, local_token()) do
      if origin == :local,
        do: {:ok, @local, @local_generation},
        else: {:error, "the built-in node's key only works on the hub machine"}
    else
      token |> hash() |> find() |> authenticate_key(origin, opts)
    end
  end

  def authenticate(_token, _origin, _opts), do: {:error, "no node key"}

  defp find(key_hash) do
    Key |> where([k], k.key_hash == ^key_hash and is_nil(k.revoked_at)) |> Repo.one()
  end

  defp authenticate_key(nil, _origin, _opts), do: {:error, "unknown node key"}

  defp authenticate_key(%Key{} = key, origin, opts) do
    case check(key, origin, DateTime.utc_now(), opts) do
      :ok -> {:ok, key.node_id, key.generation}
      {:bind, identity} -> bind(key, identity, origin, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  # Unless something else got there first (another device, or a new key),
  # in which case what's stored now decides.
  defp bind(key, identity, origin, opts) do
    {count, _} =
      Key
      |> where([k], k.node_id == ^key.node_id and k.key_hash == ^key.key_hash)
      |> where([k], is_nil(k.device) and is_nil(k.revoked_at))
      |> Repo.update_all(
        set: [
          device: identity.device,
          device_name: identity.device_name,
          expires_at: nil,
          updated_at: DateTime.utc_now()
        ]
      )

    case count do
      1 ->
        :ok = announce(key.node_id)
        {:ok, key.node_id, key.generation}

      0 ->
        key.key_hash |> find() |> authenticate_key(origin, opts)
    end
  end

  @doc """
  Whether `key` may be used from `origin` at `now`: from its own device; or,
  before it's tied to one and while it hasn't expired, from a tailnet device
  allowed to claim it (`{:bind, identity}`: tie it there) or, unless
  `require_tailnet`, from somewhere the tailnet can't name. Never from the
  hub machine itself, which only the built-in node connects from. Pure.
  """
  @spec check(Key.t(), origin(), DateTime.t(), keyword()) ::
          :ok | {:bind, Photon.Tailnet.identity()} | {:error, String.t()}
  def check(%Key{} = key, :local, _now, _opts),
    do: {:error, "#{key.node_id}'s key only works from #{key.device_name || "its own machine"}"}

  def check(%Key{device: nil, expires_at: %DateTime{} = expires} = key, origin, now, opts) do
    if DateTime.before?(now, expires),
      do: check(%{key | expires_at: nil}, origin, now, opts),
      else: {:error, "#{key.node_id}'s key expired before any machine used it. Make a new one."}
  end

  def check(%Key{device: nil} = key, {:ok, identity}, _now, opts) do
    if may_claim?(identity, Keyword.get(opts, :logins, :any)),
      do: {:bind, identity},
      else:
        {:error,
         "#{key.node_id}'s key is for one of your own machines, not #{identity.device_name}"}
  end

  def check(%Key{device: nil} = key, :error, _now, opts) do
    if Keyword.get(opts, :require_tailnet, false),
      do: {:error, "#{key.node_id}'s key only works from a machine on the tailnet"},
      else: :ok
  end

  def check(%Key{device: device}, {:ok, %{device: device}}, _now, _opts), do: :ok

  def check(%Key{} = key, {:ok, identity}, _now, _opts),
    do:
      {:error, "#{key.node_id}'s key belongs to #{key.device_name}, not #{identity.device_name}"}

  def check(%Key{} = key, :error, _now, _opts),
    do: {:error, "#{key.node_id}'s key only works from #{key.device_name} on the tailnet"}

  # The user's own devices, or tagged ones (which only tailnet admins tag).
  defp may_claim?(_identity, :any), do: true
  defp may_claim?(%{tags: [_ | _]}, _logins), do: true
  defp may_claim?(%{login: login}, logins), do: login in logins

  @doc "Whether `generation` is still `node_id`'s current key (the built-in node's always is)."
  @spec current?(String.t(), integer()) :: boolean()
  def current?(@local, @local_generation), do: true

  def current?(node_id, generation) do
    Key
    |> where([k], k.node_id == ^node_id and k.generation == ^generation)
    |> where([k], is_nil(k.revoked_at))
    |> Repo.exists?()
  end

  @doc "The tailnet devices that run nodes, or did until removed (their stable IDs)."
  @spec node_devices() :: MapSet.t(String.t())
  def node_devices do
    Key
    |> where([k], not is_nil(k.device))
    |> select([k], k.device)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc "Every key the hub knows, by node ID (no keys in them, only their hashes)."
  @spec list() :: [Key.t()]
  def list, do: Key |> order_by([k], k.node_id) |> Repo.all()

  @doc "The built-in node's key: made once per boot, kept in memory."
  @spec local_token() :: String.t()
  def local_token do
    case :persistent_term.get({__MODULE__, :local}, nil) do
      nil ->
        token = @prefix <> random(32)
        :persistent_term.put({__MODULE__, :local}, token)
        token

      token ->
        token
    end
  end

  defp announce(node_id), do: Events.broadcast(@topic, {:node_keys_changed, node_id})

  defp hash(key), do: :crypto.hash(:sha256, key)

  defp random(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
