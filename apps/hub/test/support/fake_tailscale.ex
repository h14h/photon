defmodule Photon.FakeTailscale do
  @moduledoc """
  A stand-in `tailscale` for tests (the hub runs whatever PHOTON_TAILSCALE
  names): it answers `whois --json` for the devices it's given and
  `status --json` with a status, and fails for anything else.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Writes the stand-in into `dir`, points PHOTON_TAILSCALE at it, and clears
  the hub's cached tailscale answers (again when the test exits).
  `devices` maps an address to `{stable_id, name, login}` (login nil for a
  tagged device).
  """
  def install!(dir, devices, status \\ nil) do
    whois =
      for {ip, {id, name, login}} <- devices do
        node = %{
          "StableID" => id,
          "ComputedName" => name,
          "Tags" => if(login, do: nil, else: ["tag:t"])
        }

        answer("whois --json #{ip}", %{"Node" => node, "UserProfile" => %{"LoginName" => login}})
      end

    status = if status, do: [answer("status --json", status)], else: []
    path = Path.join(dir, "tailscale")
    File.write!(path, ~s(#!/bin/sh\ncase "$*" in\n#{Enum.join(whois ++ status)}esac\nexit 1\n))
    File.chmod!(path, 0o755)

    System.put_env("PHOTON_TAILSCALE", path)
    clear_cache()

    on_exit(fn ->
      System.delete_env("PHOTON_TAILSCALE")
      clear_cache()
    end)

    path
  end

  defp answer(args, json),
    do: ~s("#{args}"\)\n  cat <<'JSON'\n#{Jason.encode!(json)}\nJSON\n  exit 0;;\n)

  defp clear_cache, do: :ets.delete_all_objects(Photon.Tailnet)
end
