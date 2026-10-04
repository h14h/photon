# Dialyzer findings that are not bugs, each with the reason. `mix dialyzer`
# lists a filter here that no longer matches anything, so stale ones go.
[
  # The jitter comes from `random`, a function argument (`:rand.uniform/1` in
  # production), whose integer result Dialyzer can't see, so it infers that
  # `backoff + jitter` might be a float.
  {"lib/photon_core/llm/retry.ex", :missing_range}
]
