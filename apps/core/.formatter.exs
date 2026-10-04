# Used by "mix format". The custom Credo checks in tools/credo_checks are
# tested from this app, so they are formatted from here too.
[
  inputs: [
    "{mix,.formatter,.credo}.exs",
    "{config,lib,test}/**/*.{ex,exs}",
    "../../tools/credo_checks/{lib,test}/**/*.{ex,exs}",
    "../../tools/credo_checks/*.exs"
  ]
]
