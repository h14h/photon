defmodule PhotonNode.Harness.Env do
  @moduledoc """
  The environment commands run with: the node's own, minus its launch
  plumbing (release scripts, or the Burrito wrapper of a packaged binary),
  which would otherwise leak into every shell the agent runs.
  """

  @burrito_lib_paths "/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:/lib:/usr/lib"

  @typedoc "Environment overrides for a port: `false` unsets a variable."
  @type overrides :: [{String.t(), String.t() | false}]

  @doc "Port `:env` overrides: `false` unsets a variable."
  @spec overrides(%{String.t() => String.t()}) :: overrides()
  def overrides(env \\ System.get_env()) do
    unset =
      for {name, _} <- env,
          name in ~w(__BURRITO __BURRITO_BIN_PATH _IS_TTY ROOTDIR BINDIR EMU PROGNAME PHOTON_NODE_TOKEN) or
            String.starts_with?(name, "RELEASE_"),
          do: {name, false}

    library_path =
      case env["LD_LIBRARY_PATH"] do
        nil -> []
        @burrito_lib_paths -> [{"LD_LIBRARY_PATH", false}]
        path -> [{"LD_LIBRARY_PATH", String.replace_suffix(path, ":" <> @burrito_lib_paths, "")}]
      end

    if Map.has_key?(env, "__BURRITO"), do: unset ++ library_path, else: unset
  end

  @doc "The shell Bash commands run in: `$SHELL` if absolute, else `/bin/sh`."
  @spec shell() :: String.t()
  def shell do
    case System.get_env("SHELL") do
      "/" <> _ = shell -> String.trim(shell)
      _ -> "/bin/sh"
    end
  end

  @doc "Overrides in the charlist form `Port.open/2` takes."
  @spec to_port(overrides()) :: [{charlist(), charlist() | false}]
  def to_port(overrides) do
    Enum.map(overrides, fn
      {k, false} -> {to_charlist(k), false}
      {k, v} -> {to_charlist(k), to_charlist(v)}
    end)
  end
end
