# Dialyzer findings that are not bugs, each with the reason. `mix dialyzer`
# lists a filter here that no longer matches anything, so stale ones go.
[
  # Code that `use Slipstream` injects into PhotonNode.Connection, reported
  # at the dependency's own line. It isn't ours to change.
  {"deps/slipstream/lib/slipstream.ex", :unmatched_return}
]
