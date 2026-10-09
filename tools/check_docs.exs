# Fails when a doc names something that doesn't exist (see
# PhotonCredo.Docs). Run from apps/hub in the test env, where every app's
# modules are compiled; `mix precommit` there does:
#
#     mix run --no-start ../../tools/check_docs.exs
Code.require_file("credo_checks/lib/photon_credo/docs.ex", __DIR__)

case PhotonCredo.Docs.run(Path.expand("..", __DIR__)) do
  [] ->
    :ok

  problems ->
    for {file, line, message} <- problems, do: IO.puts(:stderr, "#{file}:#{line}: #{message}")
    Mix.raise("check_docs: #{length(problems)} reference(s) to things that don't exist")
end
