defmodule Photon.Auth do
  @moduledoc """
  The GUI password. Required in production (and whenever `PHOTON_PASSWORD` is
  set); open in development. Without `PHOTON_PASSWORD`, one is generated on
  first boot, logged once, and kept in `<data dir>/password`.

  Nodes don't use this: they authenticate with the node token.
  """

  require Logger

  def enabled?, do: Application.get_env(:photon, :auth, false)

  def trust_tailnet?, do: Application.get_env(:photon, :trust_tailnet, false)

  def password do
    Application.get_env(:photon, :password) ||
      case :persistent_term.get({__MODULE__, :password}, nil) do
        nil -> ensure_password!()
        password -> password
      end
  end

  @doc "Loads or generates the password at boot, so a new one is logged right away."
  def ensure_password! do
    path = Path.join(Photon.Paths.data_dir(), "password")

    password =
      Application.get_env(:photon, :password) ||
        case File.read(path) do
          {:ok, saved} when byte_size(saved) > 0 ->
            String.trim(saved)

          _ ->
            generated = :crypto.strong_rand_bytes(15) |> Base.url_encode64(padding: false)
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

  def valid?(given) when is_binary(given), do: Plug.Crypto.secure_compare(given, password())
  def valid?(_), do: false

  @doc "What the session holds once a browser has signed in; changes with the password."
  def session_token do
    :crypto.hash(:sha256, "photon-gui:" <> password()) |> Base.url_encode64(padding: false)
  end
end
