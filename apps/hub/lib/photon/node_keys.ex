defmodule Photon.NodeKeys do
  @moduledoc """
  Each node's own key: what it presents to connect to the hub
  (`PhotonWeb.NodeSocket`) and to use the model relay
  (`PhotonWeb.NodeAuthPlug`). A key works for one node ID only, so a
  node can't connect as another.

  The hub keeps only each key's SHA-256 (`Photon.NodeKeys.Key`). `issue/1`
  makes a new key whenever a node is installed or updated, replacing the
  old one, and `revoke/1` removes it when the node is. The installer hands
  the key to the machine; nobody needs to see it.

  On a tailnet, a key is tied to the device that first connects with it
  (Tailscale's stable device ID, from `Photon.Tailnet.whois/1`), so a key
  copied off a machine is useless anywhere else. A hub that isn't on a
  tailnet sees no devices, and its keys stay untied. `Photon.Auth` uses
  `node_devices/0` to keep these machines out of the GUI.

  The built-in node in the hub's own BEAM (development) gets `local_token/0`
  instead: made at boot, kept in memory, and good only for node `local`
  connecting from the hub machine itself.

  `check/2` is pure.
  """

  use Boundary, deps: [Photon.Repo, Photon.Tailnet, Ecto]

  import Ecto.Query

  alias Photon.NodeKeys.Key
  alias Photon.Repo

  @prefix "pnk_"
  @local "local"

  @typedoc """
  Where a key was presented from: a tailnet device (`Photon.Tailnet.whois/1`),
  `:local` (the hub machine itself), or `:error` (somewhere the tailnet
  can't name).
  """
  @type origin :: {:ok, Photon.Tailnet.identity()} | :local | :error

  @doc "Makes `node_id` a new key, replacing (and so revoking) any it had. Returns the key."
  @spec issue(String.t()) :: {:ok, String.t()}
  def issue(node_id) do
    key = @prefix <> random(32)

    _key =
      Repo.insert!(
        %Key{node_id: node_id, key_hash: hash(key)},
        on_conflict: {:replace, [:key_hash, :device, :device_name, :updated_at]},
        conflict_target: :node_id
      )

    {:ok, key}
  end

  @doc "Removes `node_id`'s key, so nothing can connect as it."
  @spec revoke(String.t()) :: :ok
  def revoke(node_id) do
    {_count, _} = Key |> where([k], k.node_id == ^node_id) |> Repo.delete_all()
    :ok
  end

  @doc """
  The node a key belongs to, checked against where it came from (see
  `check/2`). A key's first use from a tailnet device ties it to that device.
  """
  @spec authenticate(term(), origin()) :: {:ok, String.t()} | {:error, String.t()}
  def authenticate(token, origin) when is_binary(token) do
    if Plug.Crypto.secure_compare(token, local_token()) do
      if origin == :local,
        do: {:ok, @local},
        else: {:error, "the built-in node's key only works on the hub machine"}
    else
      token |> hash() |> find() |> authenticate_key(origin)
    end
  end

  def authenticate(_token, _origin), do: {:error, "no node key"}

  defp find(key_hash), do: Key |> where([k], k.key_hash == ^key_hash) |> Repo.one()

  defp authenticate_key(nil, _origin), do: {:error, "unknown node key"}

  defp authenticate_key(%Key{} = key, origin) do
    case check(key, origin) do
      :ok ->
        {:ok, key.node_id}

      {:bind, identity} ->
        changes =
          Ecto.Changeset.change(key, device: identity.device, device_name: identity.device_name)

        _key = Repo.update!(changes)

        {:ok, key.node_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Whether `key` may be used from `origin`: from its own device; or, before
  it's tied to one, from any tailnet device (`{:bind, identity}`: tie it
  there) or from a hub without a tailnet. Never from the hub machine itself,
  which only the built-in node connects from. Pure.
  """
  @spec check(Key.t(), origin()) ::
          :ok | {:bind, Photon.Tailnet.identity()} | {:error, String.t()}
  def check(%Key{} = key, :local),
    do: {:error, "#{key.node_id}'s key only works from #{key.device_name || "its own machine"}"}

  def check(%Key{device: nil}, {:ok, identity}), do: {:bind, identity}
  def check(%Key{device: nil}, :error), do: :ok
  def check(%Key{device: device}, {:ok, %{device: device}}), do: :ok

  def check(%Key{} = key, {:ok, identity}),
    do:
      {:error, "#{key.node_id}'s key belongs to #{key.device_name}, not #{identity.device_name}"}

  def check(%Key{} = key, :error),
    do: {:error, "#{key.node_id}'s key only works from #{key.device_name} on the tailnet"}

  @doc "The tailnet devices that run nodes (their stable IDs)."
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

  defp hash(key), do: :crypto.hash(:sha256, key)

  defp random(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
