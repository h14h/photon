# Dialyzer findings that are not bugs, each with the reason. `mix dialyzer`
# lists a filter here that no longer matches anything, so stale ones go.
[
  # Integer arithmetic on arguments Dialyzer doesn't take from the spec: it
  # infers that a float could come in, so a float could come out. The
  # values are milliseconds and counters, integers wherever they're made.
  {"lib/photon/assistant/routine.ex", :missing_range},
  {"lib/photon/durable/policy.ex", :missing_range},
  {"lib/photon/durable/turn.ex", :missing_range},
  # `Phoenix.LiveView.JS.t()` keeps its operations opaque, but the
  # `JS.show/2` and `JS.hide/2` that these wrap return the struct Dialyzer
  # can see into.
  {"lib/photon_web/components/core_components.ex", :contract_with_opaque}
]
