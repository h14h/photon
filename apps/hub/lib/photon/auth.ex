defmodule Photon.Auth do
  @moduledoc """
  Who may open the GUI. The hub runs in one of these modes
  (`config :photon, :auth_mode`, from `PHOTON_AUTH`):

    * `:tailscale` - only your own devices on the hub's tailnet. The hub
      asks Tailscale which device each request comes from
      (`Photon.Tailnet.whois/1`), and `check_device/3` lets it in if it
      belongs to an allowed login (`PHOTON_TAILSCALE_USERS`, else whoever
      owns the hub machine), isn't tagged, and doesn't run a node. Machines
      that run nodes are kept out so that an agent working on one can't
      drive the hub as you.
    * `:password` - one password: `PHOTON_PASSWORD`, else one generated on
      first boot, logged once and kept in `<data dir>/password`. The
      production default.
    * `:tailscale_or_password` - your devices on the tailnet as in
      `:tailscale`, and the password for everyone else: a public hub
      that's also on your tailnet (`PHOTON_AUTH=tailscale,password`).
    * `:off` - open: development and tests, or a hub that only another
      login can reach.

  Nodes don't use this: each has its own key (`Photon.NodeKeys`).
  `check_device/3` is pure.
  """

  use Boundary, deps: [Photon.Paths, Photon.Tailnet]

  require Logger

  @type mode :: :off | :password | :tailscale | :tailscale_or_password

  @spec mode() :: mode()
  def mode, do: Application.get_env(:photon, :auth_mode, :off)

  @doc """
  Whether this hub vouches for devices through its tailnet: then node keys
  must come from a device it can name too (`Photon.NodeKeys`).
  """
  @spec tailnet?() :: boolean()
  def tailnet?, do: mode() in [:tailscale, :tailscale_or_password]

  @doc """
  How `Photon.NodeKeys.authenticate/3` treats keys here: on a hub that
  vouches through its tailnet, only from devices it can name, and an untied
  key only claimed by the allowed logins' devices (or tagged ones).
  """
  @spec node_key_policy() :: keyword()
  def node_key_policy do
    if tailnet?(), do: [require_tailnet: true, logins: tailscale_logins()], else: []
  end

  ## Tailscale

  @doc "The Tailscale logins let in: `PHOTON_TAILSCALE_USERS`, else the hub machine's owner."
  @spec tailscale_logins() :: [String.t()]
  def tailscale_logins do
    case Application.get_env(:photon, :tailscale_users, []) do
      [] -> List.wrap(Photon.Tailnet.owner_login())
      logins -> logins
    end
  end

  @doc """
  Whether a device may open the GUI in `:tailscale` mode, given who it is
  (`Photon.Tailnet.whois/1`'s answer; `:error` when it isn't on the
  tailnet), the logins let in, and the devices that run nodes. The reason
  is shown to whoever was refused.
  """
  @spec check_device({:ok, Photon.Tailnet.identity()} | :error, [String.t()], MapSet.t()) ::
          :ok | {:error, String.t()}
  def check_device(:error, _logins, _node_devices),
    do: {:error, "Photon only opens on your devices on its tailnet."}

  def check_device({:ok, %{tags: [_ | _]} = id}, _logins, _node_devices),
    do: {:error, "#{id.device_name} is a tagged device, so it isn't anyone's to let in."}

  def check_device({:ok, _id}, [], _node_devices),
    do:
      {:error,
       "No Tailscale login is allowed in: the hub machine is tagged, so set PHOTON_TAILSCALE_USERS."}

  def check_device({:ok, id}, logins, node_devices) do
    cond do
      id.login not in logins ->
        {:error, "#{id.device_name} belongs to #{id.login}, who isn't allowed in."}

      MapSet.member?(node_devices, id.device) ->
        {:error,
         "#{id.device_name} runs a Photon node, so it can't open the hub: an agent working " <>
           "there could act as you. Use another of your devices."}

      true ->
        :ok
    end
  end

  ## Password

  @spec password() :: String.t()
  def password do
    Application.get_env(:photon, :password) ||
      case :persistent_term.get({__MODULE__, :password}, nil) do
        nil -> ensure_password!()
        password -> password
      end
  end

  @doc "Loads or generates the password at boot, so a new one is logged right away."
  @spec ensure_password!() :: String.t()
  def ensure_password! do
    path = Path.join(Photon.Paths.data_dir(), "password")

    password =
      Application.get_env(:photon, :password) ||
        case File.read(path) do
          {:ok, saved} when byte_size(saved) > 0 ->
            String.trim(saved)

          _ ->
            generated = Base.url_encode64(:crypto.strong_rand_bytes(15), padding: false)
            File.mkdir_p!(Path.dirname(path))
            File.write!(path, generated)
            File.chmod!(path, 0o600)

            Logger.warning(
              "Generated a password for the Photon GUI: #{generated} (saved in #{path}). " <>
                "Set PHOTON_PASSWORD to choose your own."
            )

            generated
        end

    :persistent_term.put({__MODULE__, :password}, password)
    password
  end

  @spec valid?(term()) :: boolean()
  def valid?(given) when is_binary(given), do: Plug.Crypto.secure_compare(given, password())
  def valid?(_), do: false

  @doc "What the session holds once a browser has signed in; changes with the password."
  @spec session_token() :: String.t()
  def session_token do
    Base.url_encode64(:crypto.hash(:sha256, "photon-gui:" <> password()), padding: false)
  end
end
