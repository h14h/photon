# TLA+ learning loop

Layer 3 of the [pyramid](../README.md). A spec here is a teaching model of one
protocol worry. It is not a second implementation of Photon, and TLC passing
is not a substitute for `mix test` or for verify-photon.

The specs are idealized on purpose. Each `.tla` file says what it dropped.
When the model and `node/lib/photon_node.ex` disagree, believe the Elixir,
then either fix the model or file the drift in the module comment. Do not
silently "correct" the code from memory of the spec.

## The loop

Work in this order. Skipping to podman, or skipping to TLC before the
invariant is one sentence, produces a model nobody can oracle.

1. **English invariant.** One sentence a person can check on a log. Name the
   subjects (one `node_id`, one session, the hub volume). If the sentence
   needs "and" three times, it is two invariants.
2. **Interleavings.** List the schedules that could break that sentence:
   crash before dial, second join, deliver twice, skip an offset, hub
   process dies, node keeps appending while the socket is down. If you
   cannot name a schedule, you do not need TLA+ yet.
3. **Model, at most 15 actions.** One node, one session, constants tiny
   enough to hold in your head (`MaxLen = 3`). An action is one protocol
   step from the moduledoc, not one line of Elixir. Write the idealization
   in the header before you write `Next`.
4. **TLC.** Safety invariants in the `.cfg`. Liveness can stay a comment
   when fairness would be a lie (a crash action that is always enabled
   makes "eventually joined" false). See below for the command.
5. **Named podman scenario.** The same name as the worry, in
   [`distributed.md`](../distributed.md): `clean-machine-install` or
   `hub-restart-catchup`. The scenario injects one interleaving from step 2
   (kill the node before it dials, or kill the hub after the node has
   committed an exit).
6. **Oracle on real logs.** A command that prints pass or fail against
   files, not a feeling about the UI. The hub session log is
   `$PHOTON_DATA_DIR/sessions/<id>/events.jsonl`. The node's own log is
   `$PHOTON_NODE_DATA/node-events/<id>.jsonl` (default
   `~/.photon-node/node-events/`). The sidebar's green dot is
   `Photon.NodeRegistry` membership, which is what `registered = 1` means
   in Spec A.

## Specs in this directory

| Module | English invariant, short | Podman scenario |
| --- | --- | --- |
| `install_clean_machine` | At most one live registration per node id. No joined state without a token. A failure before join leaves the hub offline for that id. | `clean-machine-install` |
| `hub_restart_catchup` | The hub log is a prefix of the node log (each offset at most once, in order). A `done` record committed while disconnected is still on the node and is never replaced by a different hub line. After catch-up the hub high-water equals the node length. | `hub-restart-catchup` |

`hub_restart_catchup` treats `run_finished` as the durable `{"type":"exit"}`
event. Read the module header before quoting the invariant at the channel
message: `PhotonNode.Connection` pushes `"run_finished"` only while joined
and does not queue that frame. The exit line is what replay actually
retransmits.

## Running TLC

Java is enough. The TLA+ tools jar is not vendored in this repo. Upstream
ships it on the [tlaplus releases](https://github.com/tlaplus/tlaplus/releases)
page as `tla2tools.jar`.

```sh
# example: place the jar outside the repo
curl -fsSL -o /tmp/tla2tools.jar \
  https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar

cd docs/verification/tla
java -cp /tmp/tla2tools.jar tlc2.TLC -workers 2 install_clean_machine.tla
java -cp /tmp/tla2tools.jar tlc2.TLC -workers 2 hub_restart_catchup.tla
```

TLC reads the `.cfg` next to the module (`SPECIFICATION`, `INVARIANT`,
`CONSTANT MaxLen = 3` on the catch-up spec). Both configs set
`CHECK_DEADLOCK FALSE`. On Spec A, `joined` and `failed` are terminals on
purpose. On Spec B, disconnect and hub crash stay enabled after catch-up, so
a caught-up link is not a stuck state; the flag is there so the two configs
match. Turning the check on for Spec B also succeeds.

Checked with TLC 2026.09.25 (Java 21, `tla2tools.jar` from the TLA+ v1.8.0
release): `install_clean_machine` 10 distinct states, depth 7;
`hub_restart_catchup` 159 distinct states, depth 11. No invariant failed.
Every action in both `Next` disjunctions was enabled at least once.

A successful run ends with `Model checking completed. No error has been
found.` and a small distinct-state count. If your machine has no Java and
no jar, say so in the PR; do not claim TLC passed.

The catch-up config pins `MaxLen` to 3 so the log stays a teaching model.
Raising it is fine for a minute of curiosity. It does not make the spec a
model of the real session store.

## Liveness, left as a sketch

Both specs check safety only. The liveness you probably want is written as
a comment in each module:

- Spec A: if a token was issued and `FailMidInstall` is never taken, the
  happy-path actions reach `joined`. Failure is an environment step, so it
  stays in `Next` and "eventually joined" is not a property of `Spec`.
- Spec B: once the link stays up, the hub is alive, and the node stops
  committing, `Deliver` (and `Resync`, if a gap is open) drains the log.
  `Len(hubLog) = Len(nodeLog)` is the moment "hub high-water covers every
  committed offset", including `done`. It is false in the states just after
  `Rejoin`, on purpose: replay has not run yet.

When you promote a sketch to a `PROPERTY`, disable the crash and disconnect
actions (or count them with a bound that hits zero) or TLC will correctly
say the property is false.

## A worked pass, Spec B

Invariant, in English: an exit committed while the hub is down is still in
the node log afterwards, and the hub file never holds some other event at
that offset.

Interleavings that matter: `CommitDone` while `link = FALSE`; `HubCrash`
(volume keeps `hubLog`); `HubRestart`; `Rejoin` (sets `sent` from
`Len(hubLog)`, the join reply's sync offset); `DropSeen` (ingest returns
`:duplicate`); `NoticeGap` then `Resync` (hub pushes `resync` from its
cursor, node replays). `Deliver` appends only when `sent = Len(hubLog)`.

The model is those actions. TLC's `HubIsPrefix`, `ExactlyOnce`, and
`DoneSurvives` are the sentence above. The podman scenario
`hub-restart-catchup` is the same schedule with `podman kill` on the hub
and the volume left mounted. The oracle is line equality of the two jsonl
files plus a single `"type":"exit"` line, described in
[`distributed.md`](../distributed.md).
