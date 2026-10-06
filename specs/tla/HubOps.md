# HubOps: the hub-node operation protocol

`HubOps.tla` models the protocol that build step 1 introduces
(`docs/plans/step-1-machine-tools.md`, section 2): Blip's `shell` call as
a durable tool task on the hub, its op row, the websocket between hub and
node, and the node's executor with its journal, op processes and commands.
It was written against the plan, before any of the code existed; "The
code against the spec", near the end, compares it with the code as built.

Checking the plan as written found five problems in its protocol (H1 to H5
below), and a review of the plan three more (H6 to H8), which the spec
reproduced before they were fixed. The plan's protocol section is now
fixed, and the spec models the fixed protocol. Each problem can be put
back with a switch in the `Bugs` constant, and each has a
`HubOps-bug-*.cfg` that turns its switch on and shows the original
failure. Four more bug configs put back defects the
plan already ruled out (an early ack, a spawn before the journal, a start
after a cancel, no `known` flag), to show the properties catch them.

So, unlike `Durable`'s configs, the bug configs here are expected to
fail, as `Executor.tla`'s are. Every other config is expected to pass.

## What is modeled

One machine, one or two tool calls on it. Call `c` owns op `c`: op IDs are
derived from the tool task's ID, so a rerun of the call reuses its op and
two calls never share one. Other machines only share the database and the
Store line with this one, and none of the properties relate two machines.

| Part | Variables | Plan |
|---|---|---|
| Op row (durable) | `row[c]`: `st` (none, open, finished, closed), `conf` (confirmed), `cx` (cancel), `psh` (pushed), `snap` | `Photon.Machines.Op`, table `machine_ops` |
| Signal (durable) | `sig[c]` | the `"op:" <> id` signal |
| Tool task (durable) | `tst`, `tph` (execute or resume), `abReq` (abort requested), `offS` (`offline_since` set), `tres` (its result), `nres` (results recorded) | `Durable.ToolTask` running `Photon.MachineTools.Call` |
| Step process | `step[c]`: `ins` (the `Machines.start/1` commit), `send` (asking the channel to push), `park` (the `{:wait}` commit), `res` (`resume/2` reading whether the machine is online), `rc` (`resume/2`'s commit); `ron` (what it read); `skn` | the task's step under `Durable.TaskSupervisor` |
| Orphaned step | `orph`, `okn` | a step left running by a Scheduler-only crash |
| Store line | `pend[c]`: a commit that ends the call and may send `op.cancel` from inside (Stop, an error, the offline limit) has started and isn't visible yet, holding the result it records; `Busy` | `Durable.Store` |
| Channel | `chan` (none, up, stale), `cq` (its mailbox of requests from other processes), `hpend` (ack-early bug only) | `PhotonWeb.NodeChannel`, `Photon.MachineRegistry` |
| Wire | `h2n`, `n2h` | the websocket; FIFO per connection, lost when it drops |
| Node connection | `conn` (down, joining, up), `fq` (snapshots the executor forwarded, in its mailbox) | `PhotonNode.Connection` |
| Journal (durable) | `jr[c]`: `st` (none, ready, proc, completed, failed, canceled), `cx` | `<data_dir>/ops/<id>/op.json` |
| Op process | `proc[c]` (none, ck, go, jw, wait), `pcx[c]` (told to cancel) | `Ops.Shell` with the executor as its owner |
| Command | `cmd[c]` (none, running, exited, killed, lost) | the OS process group |
| Observation | `execs`, `nodeCx`, `cxEver`, `runCx`, `startCx`, `everJ`, `exitOk`, `wipeConf`, `preWipe` | none; they record history for the properties |

Snapshots are reduced to their status: `ready` (journaled on `op.start`),
`proc` (the `process` checkpoint), and the terminal `completed`, `failed`,
`canceled`, plus `lost` for the "no record of this operation" failure the
node sends without journaling. Output, `op.output` and `view_image` are
left out. Live output carries no state. A `view_image` job only reads, so
running it twice is harmless.

### Actions

| Action | Plan |
|---|---|
| `CallStart` | the model calls `shell`; `ToolTask` commits the task |
| `SchedStart` | the Scheduler starts `execute/2` (first run, or a rerun after a crash: `replay: :safe`) or `resume/2` |
| `ExecIns`, `OrphIns` | 3.2 step 5: `Machines.start/1`'s commit, `on_conflict: :nothing`, and since H5 only while the task is unfinished and not marked for abort |
| `ExecSend`, `OrphSend` | 3.2 step 5: ask the channel to push the op (`{:push_op, id}`), if the registry has a channel. As written (H1) it sent the `op.start` built in the commit |
| `ExecPark` | 3.2 step 6: the `{:wait}` commit, with `offline_since` |
| `Wake` | the signal fired or `until` passed (3.3) |
| `ResumeRead`, `ResumeCommit` | 3.2 `resume/2`: read whether the machine is online, then the commit, deciding on the row as it is then: `claim_tx`, a re-park (online: after asking the channel to push the op again, hub rule 11), or `abandon_tx` (hub rule 7), which sends `op.cancel` if a channel is registered and picks the offline result from `pushed` and `confirmed` |
| `StepError` | a step that ends its call with an error before its own commit: a raise `ToolTask` rescues, or an error result `Call` returns (hub rule 10). Its commit runs `on_interrupt` -> `cancel_tx` |
| `UserStop` | `Durable.abort` marks the task |
| `SchedAbort1`, `CommitEnd` | `Scheduler.stop_aborted`: kill the step, then the abort commit with `on_interrupt` -> `cancel_tx` (hub rule 7). Split in two because `cancel_tx` sends `op.cancel` before the commit is visible. `CommitEnd` is the second half of every commit that may send from inside: a Stop, a `StepError` or an offline abandon |
| `ChanCmd` | the channel handles `:joined` (`Machines.joined/1`), `{:push_op, id}` (`Machines.push_for/2`) or `{:command, "op.cancel", _}`. The two reads set `pushed` on each row they push `op.start` for |
| `HubRecv` | `handle_in("op.snapshot")` -> `Machines.snapshot/3` with `Machines.Rules.on_snapshot/3` (hub rules 3 to 6), then its pushes |
| `HubCommitPending` | ack-early bug only: the commit after the ack |
| `HubChanDown` | the channel of a dropped socket terminates |
| `Connect` | the node connects; `NodeChannel.join/3` registers, taking over a stale channel, and sends itself `:joined` |
| `NodeJoin` | `Connection.handle_join` pushes `Executor.snapshots/0` |
| `NodeForward` | the `Connection` handles an `Executor.Link.snapshot/1` message: pushed if joined, dropped if not |
| `NodeRecv` (`RecvStart`, `RecvCancel`, `RecvAck`) | `Executor.start/1`, `cancel/1`, `ack/1` (node rules 1, 2, 3, 6, 7) |
| `OpCheckpoint`, `OpSpawn`, `OpKill`, `CmdExit`, `OpFinish` | `Ops.Shell`: the `process` checkpoint the executor journals unless the journal says canceled (node rule 4), the spawn, a kill on cancel, the command's exit, the terminal snapshot |
| `OpJournal` | spawn-before-journal bug only |
| `NodeResume` | the executor's start-up scan, a restart after a clean exit, or node rule 2: resume an unfinished journaled op with no process, and tell it to cancel if the journal says so. `Ops.Shell`'s recovery: reattach, finish from the `exit` file, or fail when the outcome is unknown or the node stopped the command (the `stopped` marker, node rule 10) |

### Modeling choices worth knowing

Store commits are atomic steps, and nothing else commits while `Busy`.
That is the Store's one line of commits. The abort commit is two steps
because `cancel_tx` pushes `op.cancel` from inside it: the channel can
push that message, and the node can act on it, before the commit is
visible, and a hub crash in between rolls the commit back. The channel's
row reads (`:joined`, `{:push_op, id}`) wait while `Busy` too, because
since H2 they go through `Durable.commit/1`.

`resume/2`'s read of the registry and its commit are two steps, because
the node can join in between (H6). The commit reads the row again
(`claim_tx`, `abandon_tx`) and the registry too, for `op.cancel`, so it
decides on what is true then. Only the choice between re-parking and
giving up uses the earlier read, and either choice is safe on a stale
one. An offline abandon is a commit that may send from inside, so it is
split like the abort commit and a hub crash can roll it back.

The channel's mailbox is two queues, `cq` for requests from hub processes
and `n2h` for the node's pushes, and the channel may take from either.
That allows more orders than one mailbox would (a node push handled before
a request that arrived earlier), so it can only add behaviors.

The node's `Connection` mailbox is `fq`. A forward handled while the
`Connection` is down is dropped at once. While it is joining (connected,
join reply not handled yet), forwards wait in `fq`. `NodeForward` drops
them until `NodeJoin` runs and pushes them after, which covers every
position of the join reply among them. One consequence: a stale
non-terminal snapshot can reach the hub after the terminal one the join
pushed. Hub rule 5 answers it with `op.cancel`, which the node ignores or,
if it has already forgotten the op, answers with a journaled `canceled`
that the hub acks.

Time is not modeled. A parked call can wake at any moment (its `until`
passed), and an offline call that saw the machine offline at its previous
check may give up at any check after that. That is how the 10-minute limit
looks from here.

An executor-only crash is left out (it restarts, re-monitors its ops and
re-reads the journal; the journal and the commands don't change, and the
op processes don't die with it, because their calls into it catch every
exit). Its main effect on an op is `NodeResume`: a resumed op is told to
cancel when its journal says so. The code has one more, which the
hub-plus-node test found. If the executor dies after it journals a
shell's `process` checkpoint but before it answers, the shell gets
`:ignored` and stops without spawning, and the resumed op fails with
"shell execution outcome is unknown because process start was not
recorded". The command never ran, so at most once holds, but the call
gets a `failed` result that `ResultFromOwnOp` allows only after a node
restart. Op-process crashes are left out too (a
`failed` snapshot, `Executor.Rules.down/3`). `Executor.tla` models both
kinds of crash, with the executor's handlers, journal and operation
processes opened up, and checks that neither breaks at most once or the
call's result; that case is one of its reachability checks.
A step that raises is not a crash: `ToolTask` rescues it and records an
error result. That, and every error result `Call` returns, is
`StepError`. A step process that exits for another reason ends in
`on_fail`, which runs the same `cancel_tx` as a Stop.

## Faults

All bounded by constants, so every behavior ends with the node reachable.

- `Disconnect`: the websocket drops. Pushes in flight are lost both ways,
  the channel lingers as `stale` (registered, socket gone) and its mailbox
  goes nowhere.
- `HubCrash`: the hub VM restarts. SQLite survives. Steps, channels, the
  registry and a commit in progress don't. Running tasks go back to
  pending, so `execute/2` or `resume/2` reruns.
- `SchedCrash`: only the Scheduler dies. Its steps keep running under
  their `Task.Supervisor` while their tasks go back to pending and start
  again. Their task commits are fenced, but `Machines.start/1`'s commit and
  send are not.
- `NodeRestart`: the node VM restarts. The journal survives; op processes,
  the `Connection` and its mailbox don't. Each running command either
  survives (an abrupt crash, reattached later) or is killed on the way down.
- `NodeWipe`: the node loses its data directory. Commands and journal are
  gone. The protocol can't hide this; the `known` flag limits the damage.
- `UserStop`: Stop, at any time.
- `StepError`: a tool step ends its call with an error, at any of its
  points, bounded by `MaxErrors`.

`MaxRepush` bounds the re-pushes of `op.start` from online rechecks (hub
rule 11). They aren't faults, but each one adds messages to the queues,
and an unbounded number would make the state space infinite. One is
enough to check that an extra `op.start` at any point is harmless.

## Fairness

Weak fairness, per call, on every step of the hub's tasks and the node's op
processes, and on the channel, the `Connection`, connecting and joining.
A parked call keeps being checked. Calls, Stops, errors and faults get no
fairness. Commands exit on their own only when `CmdsEnd` is TRUE; with
FALSE, a command ends only when it is killed.

## Properties

The task asked for five checks. Each maps to one or more properties:

| Asked for | Property |
|---|---|
| a command runs at most once per tool call | `AtMostOnceSpawn`; with data loss, `KnownNotRerun` |
| every call gets exactly one result once the node is reachable | `OneResult` (safety), `CallAnswered` (liveness) |
| a cancel eventually takes effect | `CancelTakesEffect`, with `NoStartAfterCancel` and `NoRunAfterCancel` as its safety side |
| the node's result store doesn't grow without bound | `ResultsDropped`, `JournalUntilRecorded`; on the hub, `RowsClose` |
| no result is delivered to the wrong call | `ResultFromOwnOp`, `OfflineNotRun` |

Safety (invariants):

| Name | Meaning |
|---|---|
| `AtMostOnceSpawn` | each op's command is spawned at most once (no data loss) |
| `KnownNotRerun` | after data loss, an op the hub had confirmed is never spawned again |
| `OneResult` | a call's result is recorded at most once, and exactly once when it is done |
| `ResultFromOwnOp` | a call's result is what its own op did on the node: `completed` only if its command exited, `canceled` only after the node handled `op.cancel` for it, `failed` only after a node restart or data loss, "no record" only after data loss, an error only after a step failed, and never the "already delivered" guard |
| `OfflineNotRun` | the offline result says "the command didn't run" only if its command never ran |
| `NoStartAfterCancel` | the hub never pushes `op.start` for a row with `cancel` set |
| `NoRunAfterCancel` | the node never starts an op after it handled `op.cancel` for it |
| `JournalUntilRecorded` | the node forgets an op only after the hub recorded its result |
| `NoLiveRowAfterDone` | once a call has its result, its row is closed, finished, or open with `cancel` set; nothing may still start it |
| `ClosedOnlyWhenDone` | a row is closed only once its call has its result |
| `SignalMeansRecorded` | the signal fires only with the result in the row |

Ops IDs keep calls apart by construction, so "the wrong call" can't mean
another call's op ID. `ResultFromOwnOp` checks the rest: that a call's
result came from its own op's run, not from a stale snapshot, a cancel
nobody sent, or a node that lost the op.

Liveness:

| Name | Meaning |
|---|---|
| `CallAnswered` | every call eventually gets its result (needs `CmdsEnd`) |
| `CancelTakesEffect` | once `cancel` is set, the row eventually closes with the command not running |
| `ResultsDropped` | every terminal journal entry is eventually forgotten |
| `RowsClose` | every op row eventually closes, so no snapshot is kept for good (needs `CmdsEnd`) |

## How to run

```sh
cd specs/tla
java -XX:+UseParallelGC -cp ~/.local/share/tla/tla2tools.jar tlc2.TLC \
  -workers 4 -lncheck final -metadir /tmp/tlc-HubOps/<Cfg> \
  -config <Cfg>.cfg HubOps.tla
```

Every config turns deadlock checking off (`CHECK_DEADLOCK FALSE`): a
finished call with its budgets spent is meant to stop. `-lncheck final`
only matters for configs with `PROPERTIES`.

## Results

TLC 2.19, Java 21, 4 workers on a shared 12-core machine (2 for the bug
configs) under heavy load from other work, 2026-10-05. The clean configs
ran two at a time.

| Config | Shape | Checks | Result | Distinct states | Time |
|---|---|---|---|---|---|
| `HubOps.cfg` | 1 call; 1 disconnect, 1 hub crash, 1 Scheduler crash, 1 node restart, 1 Stop | all safety except `KnownNotRerun` | pass | 10,181,934 | 5m08s |
| `HubOps-live.cfg` | 1 call; 1 disconnect, 1 hub crash, 1 Stop | same safety; `CallAnswered CancelTakesEffect ResultsDropped RowsClose` | pass | 397,185 | 5m17s |
| `HubOps-live-node.cfg` | 1 call; 1 node restart, 1 disconnect, 1 Stop | same as `HubOps-live.cfg` | pass | 339,861 | 4m34s |
| `HubOps-cancel.cfg` | 1 call, commands run until killed; 1 disconnect, 1 hub crash, 1 node restart, 1 Stop | same safety; `CancelTakesEffect ResultsDropped` | pass | 1,180,976 | 9m06s |
| `HubOps-wipe.cfg` | 1 call; 1 data loss, 1 disconnect, 1 Stop | safety with `KnownNotRerun` in place of `AtMostOnceSpawn` and `JournalUntilRecorded`; all four liveness properties | pass | 315,072 | 4m00s |
| `HubOps-errors.cfg` | 1 call; 1 step error, 1 re-push, 1 disconnect, 1 hub crash, 1 Stop | all safety except `KnownNotRerun`; all four liveness properties | pass | 1,813,467 | 23m58s |
| `HubOps-two.cfg` | 2 calls; 1 Stop, no faults | all safety except `KnownNotRerun` | pass | 49,345,038 | 27m40s |
| `HubOps-bug-stale-start.cfg` | H1; no faults | `AtMostOnceSpawn` | fails, 24-state trace | 1,646 | 1s |
| `HubOps-bug-unserialized-read.cfg` | H2; 1 Stop, commands run until killed | `CancelTakesEffect` | fails, 18-state trace (17 steps, then stuttering) | 9,497 | 5s |
| `HubOps-bug-cancel-unjournaled.cfg` | H3; 1 hub crash, 1 Stop | `NoRunAfterCancel` | fails, 16-state trace | 6,179 | 2s |
| `HubOps-bug-keep-finished.cfg` | H4; 1 Stop | `RowsClose` | fails, 23-state trace (22 steps, then stuttering) | 9,126 | 5s |
| `HubOps-bug-unfenced-insert.cfg` | H5; 1 Scheduler crash, 1 Stop | `NoLiveRowAfterDone` | fails, 8-state trace | 269 | 1s |
| `HubOps-bug-abandon-silent.cfg` | H6; no faults, commands run until killed | `CancelTakesEffect` | fails, 21-state trace (20 steps, then stuttering) | 1,532 | 2s |
| `HubOps-bug-offline-confirmed.cfg` | H7; 1 disconnect | `OfflineNotRun` | fails, 16-state trace | 1,669 | 1s |
| `HubOps-bug-error-skips-cancel.cfg` | H8; 1 step error | `NoLiveRowAfterDone` | fails, 5-state trace | 26 | 1s |
| `HubOps-bug-ack-early.cfg` | hub rule 4 broken; no faults | `JournalUntilRecorded` | fails, 17-state trace | 716 | 1s |
| `HubOps-bug-spawn-before-journal.cfg` | node rule 4 broken; 1 node restart | `AtMostOnceSpawn` | fails, 12-state trace | 643 | 1s |
| `HubOps-bug-start-after-cancel.cfg` | hub rule 7 broken; 1 disconnect, 1 Stop | `NoStartAfterCancel` | fails, 9-state trace | 248 | 1s |
| `HubOps-bug-no-known.cfg` | node rule 3 broken; 1 data loss | `KnownNotRerun` | fails, 17-state trace | 2,168 | 1s |

Rerun in PR B (task B7, 2026-10-06), unchanged spec, 11 workers (3 for
the bug configs) on the same machine with the CPUs mostly idle: every
config ended as above, and each clean one with the same distinct-state
count. The clean ones took 1m35s (`HubOps.cfg`), 2m07s (`-live`), 1m49s (`-live-node`),
3m51s (`-cancel`), 1m38s (`-wipe`), 9m08s (`-errors`) and 8m30s (`-two`);
each bug config failed on its property within 6 seconds, with a trace of
the length given above.

"All safety" includes `OfflineNotRun`. Every config but `HubOps-errors.cfg`
sets `MaxErrors` and `MaxRepush` to 0 (and the H8 bug config sets
`MaxErrors` to 1): the step error and the re-push are checked together
with a disconnect, a hub crash and a Stop there, with liveness.

A bug config stops at its first violation, so its state count is how far
TLC got, not the size of the space.

Faults are checked with one call. Two calls with a single disconnect or
hub crash ran past ten minutes and were stopped. The protocol is per op;
two calls share only the wire, the channel, the Store line and a join's
pushes, and `HubOps-two.cfg` checks those with a Stop, which exercises the
Store line and a join that sends `op.cancel` for one op and `op.start` for
the other.

Checks that the model reaches what it should, run once with temporary
invariants on `HubOps.cfg`'s constants: TLC reached a `completed` result,
an offline result, a Stop, a `failed` result after a node restart, a
journaled "canceled before it started", a killed command, a reattached
command, an orphaned step with its send still to do, a Stop that closed
a finished row, and a node that forgot an op after the call ended. After
H6 to H8, the same check on `HubOps-errors.cfg`'s constants without the
Scheduler crash reached both offline results ("didn't run" in 10 states,
the hedged one in 12), an error result (5), a Stop (5), a command that
completed after a re-push (24), and a `canceled` result (21).

A `canceled` result needs a commit that sent `op.cancel` and was then
rolled back. The node only reports `canceled` for an op it was told to
cancel, and the commit that tells it also ends the call. In the trace a
step error's commit sends `op.cancel`, the node journals it, and the hub
crashes before the commit lands. The rerun parks again, the node's
journaled `canceled` snapshot comes in on the next join, and the call
returns it. A rolled-back Stop never gets this far: its task is still
marked for abort and ends with "Stopped by the user" after the restart.

## The findings, and how the plan was fixed

### H1. A stale `op.start` ran a finished command again

`HubOps-bug-stale-start.cfg`, `AtMostOnceSpawn`, 24 states, no faults.
`Machines.start/1` committed the row and then sent an `op.start` built
from the row it had read: `known: false`. The machine was offline at the
commit and joined right after. The join pushed its own `op.start`, the node
ran the command, the hub recorded the result and sent `op.ack`, and the
node forgot the op. Then the channel pushed the `op.start` from
`Machines.start/1`. The node had no journal and `known` was false, so it
ran the command again. A hub restart opens the same window wider: the
rerun of `execute/2` reads an open, unconfirmed row while the node's
rejoin delivers the result.

Fix (hub rule 2): only the channel builds `op.start`, from the row as it
is when it pushes. `Machines.start/1` asks the channel to push the op
(`{:push_op, id}`), and `Machines.push_for/2` returns `op.start` only for
an open row of the channel's machine without `cancel`. The channel pushes
`op.ack` after the commit that finishes the row, and it handles one message at a time, so any
`op.start` it pushes after an `op.ack` sees the finished row and isn't
sent. One sent before the `op.ack` arrives before it and finds the journal.

### H2. A join that read around the abort commit missed the cancel

`HubOps-bug-unserialized-read.cfg`, `CancelTakesEffect`, 17 steps and then
stuttering. The user pressed Stop while the machine was offline. The abort
commit's `cancel_tx` found no channel, so it sent nothing. Before that
commit was visible the node connected, and the join read the row, still
open and not canceled, and pushed `op.start`. The commit then set
`cancel`. Nothing sends `op.cancel` again until the next join, so the
command ran on with its call already over.

Fix (hub rule 2): the channel's row reads go through `Durable.commit/1`,
like the writes, so they wait for a commit in progress. Either the join
reads after the abort commit and pushes `op.cancel`, or it reads before,
and then `cancel_tx` finds the channel registered and sends `op.cancel`
itself.

### H3. A rolled-back Stop let a canceled op start

`HubOps-bug-cancel-unjournaled.cfg`, `NoRunAfterCancel`, 16 states. Stop
on a call whose row was open and the node online. `cancel_tx` sent
`op.cancel` from inside the abort commit, and the node, which hadn't got
`op.start` yet, answered "canceled before it started" without journaling
anything. The hub crashed before the commit landed, so the row was open
and not canceled. After the restart the join pushed `op.start`, and the
node, with no journal and `known: false`, started the command the user had
stopped. The task was still marked for abort, so the next abort did cancel
it, but the command had already started.

Fix (node rule 7): `op.cancel` for an op with no journal journals the
`canceled` snapshot, and it stays until `op.ack` like any result. An
`op.start` that arrives later gets that snapshot back (node rule 2) and
runs nothing. The hub records it, acks it, and the node forgets it.

### H4. A finished row whose call was stopped kept its snapshot for good

`HubOps-bug-keep-finished.cfg`, `RowsClose`, 22 steps and then
stuttering. The result came
in, the row became `finished` with its snapshot (up to 5 MB for an image),
and the user pressed Stop before the call claimed it. `cancel_tx` only
touched open rows, so the row stayed `finished` with the snapshot forever.
Nothing was delivered wrongly; it is a leak that hub rule 8 was written to
avoid.

Fix (hub rule 7): `cancel_tx` closes a finished row and clears its
snapshot. `abandon_tx`, which finds a finished row when the offline limit
and the result cross, claims it like `claim_tx`.

### H5. An orphaned step inserted a row after Stop

`HubOps-bug-unfenced-insert.cfg`, `NoLiveRowAfterDone`, 8 states. A
Scheduler-only crash left a step running, just before its
`Machines.start/1` commit, while its task went back to pending. The user
pressed Stop, the abort commit found no row to cancel, and then the
orphaned step committed the row. Its task commits are fenced, but this
commit is the `Machines` context's own. The row was open, not canceled,
and its call was over, so the next join would start the command and
nothing would ever cancel it.

Fix (hub rule 9): `Machines.start/1` inserts the row only if, in the same
commit, the tool task is unfinished and not marked for abort.

### H6. An offline abandon raced a reconnect and left the command running

`HubOps-bug-abandon-silent.cfg`, `CancelTakesEffect`, 20 steps and then
stuttering. A review of the plan found it; the spec missed it at first
because `resume/2`'s read of the registry and its commit were one step.
The call had waited past the offline limit. `resume/2` read the machine
as offline, the node joined, and the join pushed `op.start` for the open
row. Then the abandon committed. As written, `abandon_tx` only set
`cancel`, so nothing told the node, and the command ran on with its call
over until the next join. The plan contradicted itself: hub rule 7 said
the offline-limit cancel also sends `op.cancel`.

Fix (hub rule 7): `abandon_tx` does what `cancel_tx` does inside its
commit: it sets `cancel` and, if a channel is registered then, sends
`op.cancel`. The join's read waits for that commit (H2), so either the
join sees `cancel` and sends `op.cancel`, or the commit sees the channel.

### H7. "The command didn't run" when it had

`HubOps-bug-offline-confirmed.cfg`, `OfflineNotRun`, 16 states. As
written, the offline message said the command didn't run whenever the row
wasn't confirmed. But `confirmed` is set only when a snapshot reaches the
hub. In the trace, the join pushes `op.start`, the abandon commits with
the row unconfirmed, and the node runs the command anyway before
`op.cancel` arrives. The same happens without the race when the socket
drops before any snapshot arrives. A model told "didn't run" would retry,
and a command that isn't safe to run twice would run twice.

Fix (hub rules 2 and 7): `push_for/2` and the join, which already go
through `Durable.commit/1`, set `pushed` on every row they return
`op.start` for, and `abandon_tx` picks the message inside its commit:
"didn't run" only when the row was never pushed and never confirmed.

### H8. A call that ended in an error left its row open

`HubOps-bug-error-skips-cancel.cfg`, `NoLiveRowAfterDone`, 5 states.
`Durable.ToolTask` rescues a raise in `execute/2` or `resume/2` and
records it as an ordinary error result, and `on_interrupt/2` ran only on
an abort or a failure, so `cancel_tx` never touched the row. An
`execute/2` rerun could also return an early error (the machine briefly
unknown or outdated after a hub restart) after the first run had
inserted the row. Either way the row stayed open and not canceled with
the call over: the next join would start a command the model had been
told failed, and a retry would run it twice.

Fix (hub rule 10): the commit that records a rescued raise also runs
`on_interrupt/2`; every error result `Call` returns once it has the op ID
goes through `cancel_tx` in its commit; and an `execute/2` rerun that
finds the row parks without checking the machine.

### Rules the plan already had

The last four bug configs break a rule the plan already states, to show
that a property catches each one:

- `-bug-ack-early` (hub rule 4): with `op.ack` sent before the commit, the
  node forgets an op whose result the hub hasn't stored
  (`JournalUntilRecorded`, 17 states). A hub crash at that point loses the
  result, and the rejoin either runs the command again or gets "no record".
- `-bug-spawn-before-journal` (node rule 4): a node restart between the
  spawn and the `process` checkpoint resumes from `ready` and spawns again
  (`AtMostOnceSpawn`, 12 states).
- `-bug-start-after-cancel` (hub rule 7): a join that sends `op.start` for
  a canceled row starts the command before its `op.cancel` arrives
  (`NoStartAfterCancel`, 9 states).
- `-bug-no-known` (node rule 3): after the node loses its data, an op the
  hub had confirmed runs again (`KnownNotRerun`, 17 states).

## Not modeled

`view_image`, `op.output` and live output; argument checks, unknown and
outdated machines; the machine check on snapshots (a node can only report
op IDs it was sent); executor-only crashes and op-process crashes (see
above and `Executor.tla`, which keeps the op-process detail: the pid
file, background children, the `stopped` marker, F3, F8, F9, F11, K1); power loss (the journal
writes are fsynced before they are acted on); journal write failures
(node rule 8: they answer `failed` or forward without journaling, and run
nothing; a `canceled` entry for an `op.cancel` with no journal that can't
be written is answered with nothing, and the next join's `op.cancel`
tries again; a result forwarded without journaling is held in the
executor's memory until `op.ack`, and a `ready` entry it leaves behind is
deleted, so neither a resume nor a restart starts an op the hub was told
had ended); journal entries that exist but can't be read (the executor
answers `op.start` for one with an unjournaled `failed` snapshot, "It may
or may not have run.", unless a process runs the op, and `op.ack` then
forgets it); message sizes and the frame limit (node rule 9); a second hub;
output files and the 7-day sweep; an orphaned `resume/2` step (its commit
is fenced, but an abandon's `op.cancel` would already be out, and the node
would then report `canceled`, which the rerun delivers). A node restart
that kills a running command is `cmd = "lost"`, which ends as `failed`:
the `stopped` marker (node rule 10) is what makes the code agree.

## The code against the spec

Once build step 1's code was written, it was compared with this spec
action by action (task A14 in the plan). No rule in the plan's section
2.3 changed in a way the spec models, so the spec is unchanged apart from
a comment, and the results above stand without a rerun. One rule's text
grew: node rule 8 now says that a `canceled` entry for an `op.cancel` with
no journal that can't be written is answered with nothing (see "Not
modeled"). A review then found that a result forwarded without journaling
over a `ready` entry left the op runnable: a restart, or the op process's
clean exit, started it after the hub was told it hadn't run. Node rule 8
now holds such a result in memory until `op.ack` and deletes the `ready`
entry. That too is a journal write failure, so the spec is unchanged:
without one, every terminal snapshot the node sends is journaled first
or answers an op it has no entry for, and no reachable state differs.
The function names in the tables above are the code's.

Where the code is shaped differently from the actions, and why the spec
still covers it:

- `resume/2` (`Photon.MachineTools.Call`) reads the row with
  `Machines.op_state/1` before its commit, and a call that stays parked
  returns `{:wait, ...}` without reading the row again; only the claim
  (`claim_tx/2`) and the give-up (`abandon_tx/2`) read it inside their
  commits. So a call can park again on a row that finished after its
  read, where `ResumeCommit` would claim it. The park changes only the
  task and the finish only the row and the signal, so the two commits
  commute. Parking first and finishing after reaches the same state, and
  the spec allows that. A signal recorded before the park wakes the call
  at once. The re-push (`Machines.repush/1`) is sent before the park
  commit rather than inside it; it only asks the channel to read the row
  through the Store, so when it is sent doesn't matter.
- `NodeChannel.join/3` registers the channel before it sends itself
  `:joined`, so a `{:push_op, id}` or an `op.cancel` sent in between is
  handled before `:joined`, where `Connect` puts `"joined"` first in `cq`.
  The channel handles nothing before `join/3` returns, so the node still
  gets the join reply first. Each such request reads the row through the
  Store when it is handled, or is an `op.cancel` the row already calls
  for, so handling it before the join's read adds at most a duplicate
  `op.start` or `op.cancel`, which the node handles idempotently (node
  rules 2 and 7).
- `Machines.start/1` asks for a push only when its commit inserted the
  row or found it there, not after `{:error, :stopped}`, and
  `Photon.Machines.push_op/2` sends to any registered channel, `stale` ones
  included. `ExecSend` asks whenever the channel is `up`. A push request
  is only a read, so asking less often removes behaviors, and one sent to
  a channel whose socket is gone is lost, as in `ExecSend` with a `stale`
  channel.
- The node's `Connection` handles its mailbox in arrival order. A
  forward that arrived before the join reply is handled while the channel
  isn't joined, and dropped; one that arrived after it is pushed after the
  journal's snapshots. `NodeForward` allows both, and more orders besides.
  So a stale non-terminal snapshot after the join's terminal one, which
  the review of the node's connection raised, is a behavior the spec
  already has (see "Modeling choices worth knowing").
- The executor does some actions back to back that the spec takes as two:
  `op.start` for a journaled op that nothing runs sends the journaled
  snapshot and then resumes it (`RecvStart`, then `NodeResume`), and
  `op.cancel` for such an op journals the cancel and resumes it with a
  cancel (`RecvCancel`, then `NodeResume`). The other way round, a
  `process` checkpoint the journal says is canceled is two steps in the
  code. The executor answers `:cancel`, and the shell then reports
  `canceled`, which the executor journals and forwards. In between, the
  journal still says `ready` with `cancel` set, which is the state
  `OpCheckpoint` starts from, so a node restart or another `op.cancel`
  there does what the spec does from that state.
