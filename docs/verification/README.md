# Verification pyramid

How to test Photon, from a single LiveView assertion up to a crash that only
shows up when the hub and a node are really two processes. The layers are a
sequence of questions. Stop at the first layer that can answer the one you
have.

This tree assumes `.cursor/skills/verify-photon/` (draft PR #1,
`cursor/verify-photon-skill-cc77`). That directory is not on `main`. Layer 2
below is that skill. If you are on `main`, the Elixir tests in layer 1 still
exist; the browser harness does not.

```
Layer 4  container drives (podman)     kill a real hub, read events.jsonl
Layer 3  TLA+ protocol specs           interleavings of a tiny model, TLC
Layer 2  verify-photon                 headless Chrome vs mix phx.server + local
Layer 1  mix test                      LiveView and channel tests, fake node
```

## When to reach for TLA+

Use the cheapest layer that can fail the way you are worried about.

| You are asking | Layer |
| --- | --- |
| Does this function, changeset, or LiveView render the right DOM for a scripted node? | 1. `mix test` |
| Does a person, on the real dev server, with the built-in `local` node, see the composer, the sidebar, and a mock reply? | 2. [verify-photon](../../.cursor/skills/verify-photon/SKILL.md) |
| Across reconnects, duplicate offsets, gaps, and a hub crash, can a registration or an event be doubled, skipped, or invented? | 3. [TLA+](tla/README.md) |
| Does a failure TLC already flagged still hold when the hub is a process with a volume and the node is another container? | 4. [podman](distributed.md) |

Reach for TLA+ when the bug is an interleaving of the node protocol: two joins
for one `node_id`, a join without a token, a hub that marks a machine online
before the installer finished, a replay that appends an offset twice, a gap
that gets filled with the wrong event, a `run_finished` / exit record that
existed only in memory while the socket was down. Those questions are about
the state machine in `node/lib/photon_node.ex`, `PhotonNode.Connection`,
`Photon.Sessions.ingest/4`, and `PhotonWeb.NodeChannel`, not about pixels.

A normal test or the UI skill is enough when the question is local:

- Copy, DOM ids, the settings form, the empty playground: `test/photon_web/live/playground_live_test.exs` and the feature files under `.cursor/skills/verify-photon/features/`.
- "Type `help` and the mock model answers": `verify-photon drive send-message`. That drive already checks the sidebar, the transcript, and `events.jsonl` for one happy path on `local`. It does not kill the hub.
- Install-script text and a sandboxed `ssh`: `test/photon/node_install_test.exs`.
- "Offsets are line numbers": `node/test/photon_node/event_log_test.exs`.

Do not open a TLA+ spec to rename a button. Do not point verify-photon at a
protocol race and call the screenshot a proof. verify-photon starts one hub
it owns, on `127.0.0.1`, with the embedded `local` node, and it refuses a
port it did not bind. Layer 4 is a different harness.

## Layer 1 — `mix test`, fake node

Hub tests and node tests are separate Mix projects.

```sh
mix test
(cd node && mix test)
```

`test/photon_web/channels/node_channel_test.exs` already joins `node:box`
with the real channel, checks the sync map, a gap that pushes `resync`, a
duplicate-free ingest, and a reconnect that replaces the old channel pid.
`Photon.NodeInstallTest` runs `priv/node/install.sh.eex` against a fake
`ssh` and a fake binary. Nothing in this layer dials a second OS process or
restarts the BEAM out from under a volume.

The LiveView tests name the DOM ids verify-photon drives (`#composer`,
`button[title="Connect a node"]`, and the rest of the table in the skill).
When a test and the skill disagree, the LiveView is the source of the id;
update the skill, do not invent a second selector.

## Layer 2 — verify-photon

Skill path: [`.cursor/skills/verify-photon/`](../../.cursor/skills/verify-photon/SKILL.md).

One entry point, from the repo root:

```sh
.cursor/skills/verify-photon/verify-photon launch
.cursor/skills/verify-photon/verify-photon doctor
.cursor/skills/verify-photon/verify-photon drive send-message
.cursor/skills/verify-photon/verify-photon cleanup
```

That starts `mix phx.server` on `127.0.0.1` (default port **4010**), with
`PHOTON_DATA_DIR` under `/tmp/verify-photon/run/data`, open dev auth, and the
built-in `local` node. Headless Chrome (Playwright's driver, system Google
Chrome) drives the LiveView. `doctor` must print `ok` before a drive.
Evidence, including `events.jsonl` copied from the session directory, stays
under `/tmp/verify-photon/evidence/` after cleanup.

Read `features/README.md` before driving anything other than `send-message`.
Remote install, the `node/` CLI, and a second machine are out of scope for
this skill. Screenshots of the expanded install command include the node
token; the skill says not to keep those.

## Layer 3 — TLA+ thin protocol specs

Specs under [`tla/`](tla/README.md) are properties of a small state machine,
not a model of Phoenix. Each one is a handful of actions (under fifteen) and
a few invariants. They are allowed to idealize the code; the header of each
module says where.

| Spec | Question | Code it is pinned to |
| --- | --- | --- |
| [`install_clean_machine.tla`](tla/install_clean_machine.tla) | Clean machine to one online registration. A failed mid-install never leaves the hub believing the node is online. | `priv/node/install.sh.eex`, `Photon.Provision`, `PhotonWeb.NodeChannel.join/3` |
| [`hub_restart_catchup.tla`](tla/hub_restart_catchup.tla) | Join sync offsets, replay, drop seen offsets, resync on a gap, runs continue while disconnected. | `node/lib/photon_node.ex` moduledoc, `PhotonNode.Connection`, `Photon.Sessions.ingest/4` |

The learning loop (English invariant, interleavings, model, TLC, a named
podman scenario, an oracle on real logs) is [`tla/README.md`](tla/README.md).

## Layer 4 — container drives

[`distributed.md`](distributed.md) is the v1 sketch: a hub container and a
node container, the env vars the installer and the node already use
(`PHOTON_SERVER`, `PHOTON_NODE_TOKEN`, `PHOTON_PUBLIC_URL`), and two named
scenarios that inject the failures TLC cares about (`clean-machine-install`,
`hub-restart-catchup`). It is manual scaffolding, not a CI job. A compose
file that `podman compose up` would refuse to finish is written down so the
next person does not have to rediscover the ports and the volume.

## Demos

[`demos.md`](demos.md) lists four recordings, one per layer, and how each
one was produced. Play the `.cast` files with `asciinema play`. The
verify-photon clip is also an mp4 of headed Chrome.

## What you change

Add or edit specs and notes under `docs/verification/`. Do not "fix" a
protocol bug by editing only the model until it goes quiet. If TLC fails, the
invariant is either wrong for the code or the code is wrong; say which in
the module comment before changing product code.
