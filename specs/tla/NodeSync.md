# NodeSync: hub and node session replication

`NodeSync.tla` models how a node session's log reaches the hub, and how the
hub's input outbox gets inputs into that log and settles them. It follows
the code on branch `elixir-harness` after the verification fixes, faults
included. The `NodeSync*.cfg` files are the TLC runs, and every one of them
is expected to finish with no error.

The first version of this spec modeled the code before the fixes, with five
switches for candidate fixes. It found eight bugs (NS-1 to NS-8 below). All
eight are fixed in the code, the switches are gone, and the spec now models
the fixed code. Each bug's config is kept as a regression check: same
constants, same property, now passing. A review of those fixes found a
ninth (NS-9: the hub's stop could still be lost with a coordinator's
mailbox), added the property that catches it (`StopTakesEffect`) and its
config, and fixed it. `docs/verification.md` lists the ExUnit regression
test for each one.

## What is modeled

One session on one node. The protocol is per session. Sessions share only
the websocket, the `Connection` process and the join reply, and none of
the properties relate two sessions. The hub sends a small set of inputs
(`Inputs`, numbered in insertion order).

| Part | Variables | Code |
| --- | --- | --- |
| Node log (durable) | `log`; index = offset | `PhotonNode.Harness.Store` |
| Node `Connection` (lost on restart) | `conn`, `sent`, `nq` (post-join notifications in its mailbox), `dlv` (the input whose delivery call is in progress; `-1` for a stop) | `PhotonNode.Connection`, `Harness.deliver/3`, `Harness.stop/1` |
| Session coordinator (lost on crash) | `alive`, `cpc`, `mbox`, `seen`, `busy`, `llm`, `undel`, `callModel`, `stopReq`, `lastAns` | `PhotonNode.Harness.Coordinator` (the server) running `PhotonNode.Harness.Session` (the state machine), `Harness`, `Inbox` |
| Websocket | `h2n` (hub to node), `n2h` (node to hub), `reply` (join reply) | Phoenix channel, Slipstream |
| Hub SQLite (durable) | `hubSession`, `hubLog` (`node_events` + `next_offset`), `inState`, `inAns` (`node_inputs`) | `Photon.NodeSessions` |
| Hub memory | `chan` (`NodeChannel` + `NodeRegistry`), `pushed` (inputs the current channel pushed) | `PhotonWeb.NodeChannel` |
| Observation | `sigCount`: how often the `node_input:<id>` signal was recorded; `stopAsk`: a hub stop the node took while the session was working, until its hard stop input is in the log | `NodeSessions`, `Harness.stop/1` |

Log records are reduced to what the properties need: `hdr`, `in i` (an
external hub input), `ctl` (a hard stop with a node-made id), `run`,
`resp t` (a model response, `t = 1` if it has text, `0` if the text is
empty or the request failed), `idle a` (answer = the text of the response at
offset `a`), `stopped`. Turn, tool-call and operation records are left out:
the hub ignores them and they don't decide when a run starts or ends. Tool
calls are left out for the same reason, so a run is input, `run`, `resp`,
`idle`.

### Actions and the code they model

| Action | Code |
| --- | --- |
| `AppendNotify` (helper) | a `{:persist, kind, data}` effect from `Session.record/3`, which `Coordinator` runs as `Store.append/3` + `Connection.event/3` |
| `CoordInput` | `Coordinator.handle_call({:deliver, ...})`, `handle_info({:input, _})`, the drain in `slurp/1`; `Session.deliver/4`, `handle_input/3` (holds external input while a hard stop is pending), `accept_input/3`, `Inbox.accept/2` |
| `CoordDecide` | `Session.decide/1`, `handle_stop/1`, `resume_deferred/1`, `request_model_response/1`, `record_run_state/1`; `Coordinator.handle_continue(:start)` (`Session.resume/1`) when `cpc = "start"` |
| `CoordResponse` | `Coordinator.handle_info({ref, result})` / `:DOWN`, `Session.model_response/2` (`process_model_response/3`) |
| `CoordIdleTimer`, `CoordIdleStop` | `Session.arm_idle_stop/1`, `Coordinator.handle_info(:idle_stop)` (asks `Session.idle?/1`), `restart: :transient`; the delivery retry in `Coordinator.deliver/3` |
| `CoordCrash` | DynamicSupervisor restart; `Coordinator.init/1` replays the log with `Session.replay/2` (`Inbox.new(input_ids)`, a hard stop with no `stopped` re-armed by `apply_input/2`); the delivery retry |
| `NodeConnect` | Slipstream connect/join; `NodeChannel.join/3` (`Nodes.register/2`, which takes over from a replaced connection and registers the channel, then `sync_for/1`); `handle_info(:joined)` -> `resend_queued/1` |
| `NodeHandleJoin` | `Connection.handle_join/3` |
| `Replay` (helper) | `Connection.replay/3`: one `Store.read_from/2`, watermark `from + length(records)` |
| `NodeNotify` | `Connection.handle_info({:event, ...})` |
| `NodeRecvInput` | `handle_message("input")` -> `Harness.deliver/3` (`ensure_session`, then `Coordinator.deliver/3`: `ensure_started/1` and a call answered once the input is persisted) |
| `NodeRecvResync` | `handle_message("resync")` |
| `NodeRecvStop` | `handle_message("stop")` -> `Harness.stop/1`: the hard stop goes through the same call as an input, to the running coordinator or to one started for a working session (`working?/1`) |
| `HubRecv` (`Ingest`, `ApplyRecord`, `Reject`) | `NodeChannel.handle_in/3`; `NodeSessions.ingest/4` and `reject_input/3`, each one `Durable.Store` commit with `Tx.signal/3` inside; the rules are `NodeSessions.Mirror` (`place/3`, `effect/1`, `rejectable?/2`, `refused_session/2`) |
| `HubChanDown` | `NodeChannel.terminate/2` |
| `HubCreateSession`, `HubSendInput`, `HubRepush`, `HubStop` | `NodeSessions.start/3`, `send_input/3` (each a `Durable.Store` commit; pushes only a queued input), `Nodes.command/3`, `NodeChannel.handle_info({:command, "input", ...})` (one push per input per connection), `stop/1` |
| `Disconnect`, `HubRestart`, `NodeRestart` | faults (below); `Connection.handle_disconnect/2`, `handle_topic_close/3`; `PhotonNode` children; `Harness.resume_all/0`, `working?/1` |

### Modeling choices worth knowing

Notifications that will be dropped are dropped right away. The
`Connection` ignores a notification it handles while not joined, and
anything already in its mailbox when a connection drops sits ahead of the
next join reply, so that gets ignored too. `nq` therefore only holds
notifications sent while joined, and a disconnect empties it.

The join reply's arrival and `handle_join` are one step. In the real code
a notification sent between the two is handled after `handle_join`, but
with one session its record is covered by the sync entry and sits inside
the replay's snapshot, so it is dropped as a duplicate either way.

`Replay` is one step, as `replay/3` now reads the log once.

`Harness.deliver/3` blocks the `Connection` until the coordinator has
persisted the input (`dlv`). While it waits, the `Connection` handles
nothing else, so connect, join, notify and the other `NodeRecv*` actions
require `dlv = 0`. A websocket drop can still happen; the `Connection`
handles it once the call returns. If the coordinator dies first (crash or
idle stop), the call exits and is retried with the next coordinator, which
the model writes as the successor starting with the input in its mailbox
(`Retry`). A node restart loses the call; the input is still `queued` at
the hub and is resent on the next join. `Harness.stop/1` delivers its hard
stop the same way (`dlv = -1`), so a stop also survives a coordinator
crash or idle stop. A stop lost with a node restart is gone: the hub
doesn't resend stops.

Deferral during a stop is written as `CoordInput` not taking an unseen
external input while `stopReq` holds. Stops finish in the next
`CoordDecide` here (no operations), so this is the same as the code's
in-memory hold.

The config part of a delivery (`Session.deliver/4` with a config) is left out. It only records a
settings input when the hub's config differs from the log's, and the
hub's session config is fixed by `start/3` and is the config that created
the log. They never differ.

The idle-stop race is two steps. `CoordIdleTimer` fires only while the
coordinator is idle with an empty mailbox, since every decide re-arms the
10-minute timer. After that `:idle_stop` is ahead of anything new.

Model calls always come back (retries end in a failed response), so
`CoordResponse` is weakly fair.

## Faults

All of these are bounded by constants, so every behavior ends with stable
connectivity, which is the assumption under the liveness properties.

- `Disconnect`: the websocket drops, or a channel or `Connection` crashes.
  Pushes in flight both ways are lost. The hub's channel stays registered
  for a while (`chan = "stale"`), and commands sent to it are lost.
- `HubRestart`: SQLite survives; channels and the registry don't.
- `NodeRestart`: the log survives. The `Connection`, the coordinator, both
  mailboxes and a delivery in progress are lost. `resume_all` restarts the
  session if it was working (last state `running`, or an external input
  after the last response or stop).
- `CoordCrash`: the coordinator crashes and is restarted from its log. Its
  mailbox is lost; a delivery in progress is retried.
- `IdleStopRace`: an input reaches a coordinator that is exiting after
  `:idle_stop`.
- `MaxRejects`: `ensure_session` refuses to create the session (missing
  workspace directory), so the node sends `input_rejected`.
- `MaxRepush`: the hub sends an input id it already has (NodeWork reruns a
  tool call after a hub restart with the same ids; `send_input` racing a
  join gives the same pair of messages). It is pushed only while still
  `queued`, and a channel pushes an id once.
- `MaxStops`: the hub sends `stop`. The node delivers it if a coordinator
  is running or the log says the session is working; otherwise there is
  nothing to stop.

Not modeled: power loss (a record a reader saw before `datasync` finished
could vanish), log deletion (`delete_session`), several sessions, several
nodes sharing an id, tool calls and operations (see `Coordinator.tla`), the
`live` stream.

## Fairness

Weak fairness on every process step: coordinator input, decide, model
response and idle stop; `Connection` connect, join, notification, input,
resync and stop; hub receive and channel cleanup. There is no fairness on
user actions (create session, send, stop), on the idle timer, or on faults.

## Properties

Safety (invariants):

- `HubPrefix`: the hub's copy is always a prefix of the node log.
- `InputAtMostOnce`: each input id is in the node log at most once.
- `SignalAtMostOnce`: the signal is recorded at most once per input.
- `HubAcceptedInLog`: `accepted` or `done` only after the hub holds the
  input's record.
- `SettledHasSignal`: a `done` or `failed` input always has its signal
  (one commit).
- `NoStaleAnswer`: no input is settled with the answer of a run that
  finished before the input was accepted.
- `AnswerAfterInput` (stricter): the answer was produced after the input
  was accepted.
- `RejectedNeverRuns`: an input the hub settled as `failed` is not in the
  node log.
- `StopHonored`: after a hard stop record, the next run-state record is
  `stopped`.
- `NoInputDuringStop`: no external input is logged between a hard stop and
  its `stopped` record.

Liveness (temporal):

- `Converges`: `<>[](hubSession => hubLog = log)`.
- `QueuedAccepted`: `queued ~> (in the node log \/ failed)`.
- `AcceptedSettled`: `in the node log ~> (done or failed, and signal recorded)`.
- `SettledSignaled`: `(done \/ failed) ~> signal recorded`.
- `StopTakesEffect`: `stopAsk ~> ~stopAsk`: a stop the node takes while
  the session is working gets its hard stop input into the log, unless the
  node VM restarts first. `StopHonored` then makes `stopped` the next run
  state. (It doesn't ask for `stopped` itself: a run can end on its own
  before the stop is handled, and the stop then waits in the log for the
  next start.)

## How to run

```sh
cd specs/tla
java -XX:+UseParallelGC -cp ~/.local/share/tla/tla2tools.jar tlc2.TLC \
  -workers auto -deadlock -difftrace -metadir /tmp/tlc-NodeSync/<Cfg> \
  -config <Cfg>.cfg NodeSync.tla
```

Add `-lncheck final` for configs with `PROPERTIES`. `-deadlock` is needed
because every behavior ends: inputs are finite, and the final quiet state
has no enabled steps. `-difftrace` prints only the variables that change at
each step.

## Results

TLC 2.19, Java 21, 4 workers on a shared 12-core machine at load around
38, `-deadlock`, `-lncheck final` for liveness. Every config: no error.
The numbers are from the review's rerun, after the NS-9 change; configs
with a stop changed a little, the others not at all.

| Config | Faults and extras | Checked | Distinct states | Time |
| --- | --- | --- | --- | --- |
| `NodeSync.cfg` | 2 inputs; 1 disconnect, 1 hub restart, 1 node restart, 1 coordinator crash, idle-stop race | `TypeOK HubPrefix InputAtMostOnce SignalAtMostOnce HubAcceptedInLog SettledHasSignal NoStaleAnswer AnswerAfterInput` | 280,502 | 14s |
| `NodeSyncOutbox.cfg` | 2 inputs; 1 disconnect, 1 refused delivery, 1 repeated send | safety + `RejectedNeverRuns` | 39,628 | 3s |
| `NodeSyncStops.cfg` | 2 inputs; 1 disconnect, 1 stop | safety + `StopHonored NoInputDuringStop NoStaleAnswer` | 88,723 | 5s |
| `NodeSyncNet.cfg` | 2 inputs; 1 disconnect, 1 hub restart | safety + all four input liveness properties | 36,435 | 33s |
| `NodeSyncFixedNet.cfg` | 2 inputs; 1 disconnect, 1 hub restart, 1 stop | safety + stop properties + all liveness (`StopTakesEffect` included) | 254,532 | 4m12s |
| `NodeSyncFixedProc.cfg` | 2 inputs; 1 node restart, 1 coordinator crash, idle-stop race | safety + all input liveness | 39,177 | 35s |
| `NodeSyncFixedOutbox.cfg` | 1 input; 1 disconnect, 1 refused delivery, 1 repeated send, 1 stop | safety + `RejectedNeverRuns StopHonored NoInputDuringStop` + all liveness (`StopTakesEffect` included) | 10,587 | 10s |
| `NodeSyncReplayRace.cfg` | NS-1 regression: 1 input, 1 disconnect | `Converges` | 710 | 1s |
| `NodeSyncResume.cfg` | NS-2 regression: 1 node restart | `AcceptedSettled` | 781 | 1s |
| `NodeSyncMailbox.cfg` | NS-3 regression: 1 coordinator crash | `QueuedAccepted` | 5,481 | 3s |
| `NodeSyncIdleStop.cfg` | NS-4 regression: idle-stop race | `QueuedAccepted` | 2,703 | 3s |
| `NodeSyncSignal.cfg` | NS-5 regression: 1 hub restart | `SettledSignaled AcceptedSettled` | 662 | 2s |
| `NodeSyncStaleAnswer.cfg` | NS-6 regression: no faults | `NoStaleAnswer AnswerAfterInput` | 2,083 | 1s |
| `NodeSyncReject.cfg` | NS-7 regression: 1 refused delivery, 1 repeated send | `RejectedNeverRuns` | 310 | 1s |
| `NodeSyncStop.cfg` | NS-8 regression: 1 stop, 1 node restart, 1 coordinator crash | `StopHonored NoInputDuringStop` | 10,648 | 2s |
| `NodeSyncStopLost.cfg` | NS-9 regression: 1 stop, 1 coordinator crash, 1 node restart, idle-stop race | `StopTakesEffect QueuedAccepted AcceptedSettled` + `StopHonored NoInputDuringStop` | 13,356 | 8s |

The state counts are much smaller than in the first version (`NodeSync.cfg`
had 11.9M distinct states): the double read in `replay/3`, the pending
signals and the fire-and-forget delivery each added interleavings the code
no longer has, and a blocked `Connection` interleaves less.

After the node refactor (2026-10-03), which moved the coordinator's logic
into the pure `PhotonNode.Harness.Session` and changed only comments here,
all 16 configs were re-run: no error, and the same distinct-state counts
as in the table.

After the hub refactor (2026-10-03), which routed every node-session
write through `Durable.Store`, moved the mirror's rules into the pure
`Photon.NodeSessions.Mirror`, and again changed only comments here, all 16
configs were re-run: no error, same counts.

## The findings, and how they were fixed

The traces below are from the first version of the spec (the code before
the fixes). Line numbers in them refer to that snapshot.

### NS-1. Replay dropped records written between its two file reads

`replay/3` read the log with `Store.read_from/2`, and when that returned
nothing it computed the watermark with `Store.count/1`, a second read. A
record the coordinator appended between the two reads wasn't pushed, but
`sent` moved past it, so its notification was dropped as a duplicate. The
hub never saw a gap, so its copy stayed one record short (often the final
`idle`, so inputs never settled) until the next reconnect. Every join takes
this path for every caught-up session. TLC trace: 25 states.

Fix: `replay/3` takes the watermark from the same read
(`from + length(records)`); `Store.count/1` is gone.

### NS-2. A node restart could strand an input logged but not yet running

`resume_all` restarted only sessions whose last state record was `running`.
The coordinator writes `input`, drains its mailbox, writes `turn`, then
`running`. A node restart in that window left the input `accepted` on the
hub (so never resent) and the session not resumed. TLC trace: 16 states.

Fix: `Harness.working?/1` is also true when an external input follows the
last `model_response` or `stopped` record.

### NS-3. Inputs in a crashed coordinator's mailbox were lost

`Harness.deliver` sent the input with a plain `send` and returned `:ok`. A
coordinator crash before it persisted the input lost its mailbox, and the
hub only resends `queued` inputs on join. TLC trace: 14 states.

Fix: delivery is a `GenServer.call` answered once the input is persisted
(or known as a repeat). If the coordinator dies first, `deliver` waits for
it to go and retries with its successor, up to five times.

### NS-4. The idle-stop race lost an input sent to an exiting coordinator

An input sent after `:idle_stop` was dequeued went to the exiting process.
TLC trace: 27 states. Fix: the same synchronous delivery with retry; the
call to the exiting coordinator exits and goes to a new one.

### NS-5. Settle and reject fired the signal after their commit

`ingest/4` committed the settle and only then called `Durable.signal`;
`reject_input/3` did the same in two steps. A hub restart in between lost
the signal for good (the node never resends a record the hub holds). Also
H3 in `docs/architecture.md`. TLC trace: 26 states.

Fix: `ingest/4` and `reject_input/3` run as one `Durable.Store` commit with
`Tx.signal/3` inside, so settling and the signal are atomic and announced
to the scheduler together. Broadcasts happen after the commit.

### NS-6. An input could be settled with the previous run's answer

`last_answer` was only updated by a response with text and never cleared,
so a run whose last response had no text (or failed) reported the previous
run's answer. TLC trace: 37 states.

Fix: accepting an external input clears `last_answer` and `last_failure`
(in `apply_input/2`, so replay agrees).

### NS-7. An input the hub marked failed could still run

`send_input` pushed even when the input existed already (tool reruns reuse
ids), and `send_input` racing a join pushed two copies. A refusal followed
by an acceptance left the hub at `failed` while the node ran it. TLC
trace: 11 states.

Fix: `send_input` pushes only an input that is still `queued`, and
`NodeChannel` pushes an input id at most once per connection (the node
answers each delivery for good, so a second copy could only undo a
refusal).

### NS-8. A hard stop was forgotten if the coordinator restarted before `stopped`

Replay ignored hard stops, so a crash or node restart between the stop
record and `stopped` brought the coordinator back without the stop. TLC
trace: 13 states.

Fix: `apply_input/2` arms the stop for a hard control input, and a
`stopped` record clears it, so replay re-arms a pending stop. External
input that arrives while a stop is finishing is held until `stopped` is
written (this also fixes Coordinator F4).

### NS-9. The hub's stop was still lost with a coordinator's mailbox

Found by reviewing the NS-3/NS-4 fix, then modeled. `Harness.stop/1` sent
the hard stop as a plain message, and only if a coordinator was running.
A coordinator that crashed (or stopped for idleness) before handling it
took the stop with it, and its successor carried on with the work; a stop
that arrived while no coordinator ran (just after a crash, or after a node
restart before `resume_all` got to the session) was dropped although the
log said the session was working. The hub sends a stop once. The first
spec had no property about stops taking effect, so nothing flagged it.

`StopTakesEffect` with the old `NodeRecvStop` fails in
`NodeSyncStopLost.cfg`: 28-state trace, a stop taken while the session is
running, then a coordinator crash, and the run finishes as if never
stopped.

Fix: `Harness.stop/1` goes through the same call as `deliver/3` (answered
once the stop is in the log, retried with the next coordinator), and also
starts a coordinator for a session whose log says it is working.

### Modeling artifacts found earlier

- The first idle-stop action could lose inputs queued before the timer
  fired, which a FIFO mailbox rules out. It became two steps.
- The first `NoStaleAnswer` also flagged steering within one run; the
  strict form became `AnswerAfterInput`, which now holds too.
- One all-faults config grew past 50M states and was split by fault
  family.
- The first `StopTakesEffect` (in the review) waited for `stopped`, and
  TLC found a trace where the run finished on its own before the stop was
  handled: the stop was logged, the node restarted, and the session,
  idle, wasn't resumed. Nothing was lost; the stop waits in the log. The
  property now waits for the hard stop input in the log, and
  `StopHonored` covers what follows it.
