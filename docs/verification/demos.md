# Demo recordings

Four recordings, one per layer of the [pyramid](README.md). Play a `.cast`
with [asciinema](https://asciinema.org/):

```sh
asciinema play docs/verification/demos/01-mix-test.cast
```

Nothing here is git LFS. The repo does not use it. The casts are a few
kilobytes. The verify-photon mp4 is a short H.264 capture of the desktop.
Stills are the PNGs the drives themselves wrote, or screenshots of the
podman hub. No frame contains `PHOTON_NODE_TOKEN`.

These were produced on a Linux desktop with Elixir 1.20.4 / OTP 27.3.4,
Go 1.27.1 (only to build `unreal-agent-runner` before the clips), Chrome,
and asciinema 2.4. The casts start after `mix setup` and the runner build,
so they show the check, not the download.

## (a) Layer 1 — `mix test`

`docs/verification/demos/01-mix-test.cast`

```sh
asciinema play docs/verification/demos/01-mix-test.cast
```

What it is: `mix test --trace` in the hub project, then the same in `node/`.
No `mix phx.server`. The hub suite is the fake-node layer: LiveView tests
plus `PhotonWeb.NodeChannelTest`, which joins `node:box`, checks the sync
map, a gap that pushes `resync`, and a reconnect that replaces the old
channel. The node suite checks `EventLog` offsets and one real
`unreal-agent-runner` start. The cast ends at `60 passed` and `7 passed`.

Produced with `asciinema rec -c` after the test env was already compiled,
so the clip is the run (about three seconds), not Hex downloads.

## (b) Layer 2 — verify-photon send-message

| File | What |
| --- | --- |
| `02-verify-photon-send-message.cast` | The CLI: `launch`, `doctor`, `drive send-message`, `cleanup` |
| `02-verify-photon-send-message.mp4` | Headed Chrome during that drive (about 11s) |
| `02-action.png` | Evidence still, composer filled with `help`, before Send |
| `02-result.png` | Evidence still, mock reply, `RUN FINISHED`, sidebar `local` |

```sh
asciinema play docs/verification/demos/02-verify-photon-send-message.cast
```

The skill on this branch is `.cursor/skills/verify-photon/`. Doctor in the
cast prints `ok`, `node=local`, `provider=mock`, and a data dir under
`/tmp/verify-photon`. The drive writes `/tmp/verify-photon/evidence/send-message/`.
Cleanup removes the server and keeps that evidence. The two PNGs are copies
of `action.png` and `result.png` from that directory.

The skill launches Chrome headless (`browser.mjs` sets `headless: true`).
For the mp4 only, `CHROME_PATH` pointed at a wrapper outside the repo that
drops `--headless` and execs the system Chrome. The skill files were not
edited. ffmpeg grabbed the X display (`x11grab`, 1920×1200, 12 fps) from
the moment the drive was about to open the browser through the result and
cleanup. The clip shows the empty playground, `help` in the composer, Send,
the mock sentence, and `RUN FINISHED`, with `local` in the sidebar.

## (c) Layer 3 — TLC

`docs/verification/demos/03-tlc.cast`

```sh
asciinema play docs/verification/demos/03-tlc.cast
```

Both specs, back to back, from `docs/verification/tla`. The cast prints the
invariant names, then:

```sh
java -cp /tmp/tla2tools.jar tlc2.TLC -workers 2 -cleanup \
  -metadir /tmp/tlc-rec-a install_clean_machine.tla
java -cp /tmp/tla2tools.jar tlc2.TLC -workers 2 -cleanup \
  -metadir /tmp/tlc-rec-b hub_restart_catchup.tla
```

`-metadir` and `-cleanup` keep TLC's state directory out of the repo. Each
run ends with `Model checking completed. No error has been found.` Spec A
is 10 distinct states. Spec B (`MaxLen = 3`) is 159. No counterexample:
both models satisfy the safety invariants. A failing invariant would print
a state trace instead of that sentence. Liveness stays a comment in the
modules and is not in this clip.

## (d) Layer 4 — podman catch-up

| File | What |
| --- | --- |
| `04-podman-hub-restart-catchup.cast` | `podman kill` / `podman start` and the jsonl oracle |
| `04-sidebar-before.png` | Hub page before the run, node `box` with a green dot |
| `04-sidebar-after.png` | Same hub after restart, `box` back, this session `RUN FINISHED` |

```sh
asciinema play docs/verification/demos/04-podman-hub-restart-catchup.cast
```

This one did run. Podman 4.9.3, rootless, image `photon-demo-base` (Ubuntu
24.04 plus `git`, `libncurses6`, and `libssl3`, so the host's Elixir/OTP
install can boot). Two containers on network `photon-demo`:

- `photon-hub`: `mix phx.server` with `PHOTON_BIND=0.0.0.0`,
  `PHOTON_PUBLIC_URL=http://photon-hub:4000`, `PHOTON_LOCAL_NODE=false`,
  `PHOTON_DATA_DIR` on a bind mount, port `127.0.0.1:4000`.
- `photon-node`: `cd node && mix run --no-halt` with
  `PHOTON_SERVER=ws://photon-hub:4000/node/websocket`,
  `PHOTON_NODE_ID=box`, `PHOTON_NODE_DATA` on its own bind mount, and
  `PHOTON_NODE_TOKEN` taken from the hub data dir. The cast does not print
  the token.

The clip sends `sleep 12` on `box`, kills the hub while the node log has 6
lines and no exit, waits until the node commits `{"type":"exit"}` (hub file
still 6 lines, 0 exits), starts the same hub container on the same data
mount, and waits until the files match: `hub_lines=10 node_lines=10
equal=True`, one exit on each side, and the sidebar lists `box` again.

That is Spec B's safety oracle (the exit line showed up once after
reconnect). It is not a claim about the in-memory "N running" chip. That
chip follows the `status` / `run_finished` channel frames, which
`PhotonNode.Connection` does not queue across a disconnect. The TLA model
says this in its header: the durable stand-in is the exit event. The cast's
numbers are that event.

The compose file in [`distributed.md`](distributed.md) is still not a CI
job. This recording is one manual pass of the `hub-restart-catchup`
scenario, with the hub and node built from the checkout instead of
`docker build -t photon .`.
