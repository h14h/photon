# Demo recordings

Four short screen recordings, one per layer of the [pyramid](README.md).
None of them are recorded yet. Drop the files at the paths below when they
exist. `demos/.gitkeep` is only there so the directory stays in git.

Keep node tokens out of every frame. The Add a node panel's install command
contains `PHOTON_NODE_TOKEN`. Crop before that disclosure, or do not expand
**Any other machine**.

## (a) Layer 1 — `mix test`

`docs/verification/demos/01-mix-test.mp4`

A terminal in the repo. Run `mix test`, then `(cd node && mix test)`. The
interesting moment is a channel test name from
`test/photon_web/channels/node_channel_test.exs` scrolling past (join, sync
map, resync, reconnect replaces the old channel), and a green summary. No
browser. This is the fake-node layer, so the recording should not show
`mix phx.server`.

## (b) Layer 2 — verify-photon send-message

`docs/verification/demos/02-verify-photon-send-message.mp4`

Requires [`.cursor/skills/verify-photon/`](../../.cursor/skills/verify-photon/SKILL.md),
which is not on `main` (draft PR #1).

Show, in order:

1. `.cursor/skills/verify-photon/verify-photon doctor` printing `ok`,
   `node=local`, `provider=mock`, and a data dir under `/tmp/verify-photon`.
2. The drive: `.cursor/skills/verify-photon/verify-photon drive send-message`.
3. The page itself, or the evidence screenshots the drive writes
   (`action.png` with `help` in the composer, `result.png` with the mock
   reply and the sidebar still showing `local`).
4. `events.jsonl` in the evidence directory containing the prompt and
   `model_response`. That file is the copy of the hub session log, not a
   file the recording author wrote by hand.

Cleanup can be a last frame (`verify-photon cleanup`) with the evidence
directory still present.

## (c) Layer 3 — TLC on one spec

`docs/verification/demos/03-tlc-install-clean-machine.mp4`

A terminal on `docs/verification/tla`. Show the header comment of
`install_clean_machine.tla` (the state names and `FailedStaysOffline`) only
long enough to see what is being checked, then:

```sh
java -cp /tmp/tla2tools.jar tlc2.TLC -workers 2 install_clean_machine.tla
```

The last frame is TLC reporting that the invariants held, with the
distinct-state count visible. If you would rather show Spec B, name the
file `03-tlc-hub-restart-catchup.mp4` and say so in the PR; one spec is
enough for this clip. Do not edit the spec on camera to force a pass.

## (d) Layer 4 — podman catch-up

`docs/verification/demos/04-podman-hub-restart-catchup.mp4`

The `hub-restart-catchup` scenario in [`distributed.md`](distributed.md).
Until that scaffolding is automated, the recording is a person following
the manual steps.

Show:

1. Sidebar with the remote node id on a green dot (not only `local`).
2. `podman kill` on the hub container, volume not removed.
3. The node's `node-events/<id>.jsonl` gaining or already holding a
   `"type":"exit"` line while the hub is down.
4. Hub started again on the same volume. Sidebar green dot returns, one row.
5. The two jsonl files side by side: same line count, one exit line on the
   hub. That is the oracle, and it should be readable without pausing on a
   token or a password. Blur `/data/password` and `node-token` if either
   would otherwise be on screen.

A still of `podman ps` is not this demo. The kill and the jsonl comparison
are the point.
