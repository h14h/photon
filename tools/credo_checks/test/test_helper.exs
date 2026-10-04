# Tests for Photon's custom Credo checks. They run with apps/core's suite
# (its `test_paths` include this directory). The checks are loaded the way
# Credo loads them from each app's .credo.exs (`requires:`), not compiled
# into an app.
"../lib/**/*.ex"
|> Path.expand(__DIR__)
|> Path.wildcard()
|> Enum.sort()
|> Enum.each(&Code.require_file/1)

# `mix precommit` runs `mix credo` in the same VM first, which leaves
# Credo's services running without its application marked as started.
case Application.ensure_all_started(:credo) do
  {:ok, _apps} -> :ok
  {:error, {:credo, {{:already_started, _pid}, _start}}} -> :ok
end
