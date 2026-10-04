# A property that pins an open bug is tagged :known_bug and left out of the
# default run (`mix test --include known_bug` runs it). None are open now:
# the ones the verification pass found are fixed and run by default (see
# docs/verification.md). Logs are captured, so a failing test shows its own.
ExUnit.start(exclude: [:known_bug], capture_log: true)
