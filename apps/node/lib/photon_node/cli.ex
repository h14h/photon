defmodule PhotonNode.CLI do
  @moduledoc """
  Entry point when running as a self-contained executable (`mix photon.package`).

  The Burrito wrapper boots the release and then hands its arguments to
  Elixir's CLI, which halts once it has processed them. So `boot/0` runs
  first, from `PhotonNode.Application.start/2`: it answers `--version` and
  `--help` and halts, or else keeps the VM up for the node to run. Stopping
  still works as usual: SIGTERM shuts the VM down cleanly.
  """

  use Boundary, deps: []

  @usage """
  photon-node: runs Photon agent sessions on this machine for a Photon hub.

  Usage: photon-node [--version | --help]

  Configure with environment variables:
    PHOTON_SERVER          hub websocket, e.g. ws://hub.tailnet.ts.net:4000/node/websocket
    PHOTON_NODE_TOKEN      the hub's node token (required)
    PHOTON_NODE_ID         this node's name (default: the hostname)
    PHOTON_NODE_DATA       data directory (default: ~/.photon-node)
    PHOTON_NODE_WORKSPACE  agent workspace (default: <data>/workspace)
  """

  @doc "Whether the node runs as a packaged executable."
  @spec standalone?() :: boolean()
  def standalone?, do: System.get_env("__BURRITO") != nil

  @doc "Answers `--version` and `--help` and halts, or keeps the VM up for the node."
  @spec boot() :: :ok | no_return()
  def boot do
    :ok = colors(System.get_env("_IS_TTY") == "1")
    run(Enum.map(:init.get_plain_arguments(), &List.to_string/1))
  end

  defp run([]) do
    if System.get_env("PHOTON_NODE_TOKEN") in [nil, ""],
      do: halt_with_usage("PHOTON_NODE_TOKEN is not set", 1)

    # Elixir's CLI runs at_exit hooks before halting; this one never
    # returns, so the VM stays up until it is stopped.
    System.at_exit(fn _status -> Process.sleep(:infinity) end)
  end

  defp run([flag]) when flag in ~w(--version -v version) do
    IO.puts(Application.spec(:photon_node, :vsn))
    System.halt(0)
  end

  defp run([flag]) when flag in ~w(--help -h help) do
    IO.write(@usage)
    System.halt(0)
  end

  defp run(args), do: halt_with_usage("unexpected arguments #{Enum.join(args, " ")}", 2)

  @spec halt_with_usage(String.t(), non_neg_integer()) :: no_return()
  defp halt_with_usage(problem, status) do
    IO.puts(:stderr, "photon-node: #{problem}\n\n" <> @usage)
    System.halt(status)
  end

  # Burrito forces ANSI on; under systemd or a log file that is just noise.
  defp colors(true = _tty), do: :ok

  defp colors(false = _tty) do
    Application.put_env(:elixir, :ansi_enabled, false)
    formatter = Logger.Formatter.new(colors: [enabled: false])

    # Cosmetic: if the handler can't be updated, log lines keep their colors.
    _ = :logger.update_handler_config(:default, :formatter, formatter)
    :ok
  end
end
