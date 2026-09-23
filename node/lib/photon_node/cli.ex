defmodule PhotonNode.CLI do
  @moduledoc """
  Entry point when running as a self-contained executable (`mix photon.package`).

  The Burrito wrapper boots the release and then hands its arguments to
  Elixir's CLI, which halts once it has processed them. So `boot/0` runs
  first, from `PhotonNode.Application.start/2`: it answers `--version` and
  `--help` and halts, or else keeps the VM up for the node to run. Stopping
  still works as usual: SIGTERM shuts the VM down cleanly.
  """

  @usage """
  photon-node: runs unreal-agent harnesses on this machine for a Photon hub.

  Usage: photon-node [--version | --help]

  Configure with environment variables:
    PHOTON_SERVER          hub websocket, e.g. ws://hub.tailnet.ts.net:4000/node/websocket
    PHOTON_NODE_TOKEN      the hub's node token (required)
    PHOTON_NODE_ID         this node's name (default: the hostname)
    PHOTON_NODE_DATA       data directory (default: ~/.photon-node)
    PHOTON_NODE_WORKSPACE  agent workspace (default: <data>/workspace)
    PHOTON_RUNNER          unreal-agent-runner to use instead of the bundled one
  """

  def standalone?, do: System.get_env("__BURRITO") != nil

  def boot do
    unless System.get_env("_IS_TTY") == "1", do: disable_colors()

    case Enum.map(:init.get_plain_arguments(), &List.to_string/1) do
      [] ->
        if System.get_env("PHOTON_NODE_TOKEN") in [nil, ""] do
          IO.puts(:stderr, "photon-node: PHOTON_NODE_TOKEN is not set\n\n" <> @usage)
          System.halt(1)
        end

        # Elixir's CLI runs at_exit hooks before halting; this one never
        # returns, so the VM stays up until it is stopped.
        System.at_exit(fn _status -> Process.sleep(:infinity) end)

      [flag] when flag in ~w(--version -v version) ->
        IO.puts(Application.spec(:photon_node, :vsn))
        System.halt(0)

      [flag] when flag in ~w(--help -h help) ->
        IO.write(@usage)
        System.halt(0)

      args ->
        IO.puts(
          :stderr,
          "photon-node: unexpected arguments #{Enum.join(args, " ")}\n\n" <> @usage
        )

        System.halt(2)
    end
  end

  # Burrito forces ANSI on; under systemd or a log file that is just noise.
  defp disable_colors do
    Application.put_env(:elixir, :ansi_enabled, false)

    :logger.update_handler_config(
      :default,
      :formatter,
      Logger.Formatter.new(colors: [enabled: false])
    )
  end
end
