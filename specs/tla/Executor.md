# Executor: the node's executor, journal and operation processes

`Executor.tla` models how a node runs the hub's operations: the executor
(`apps/node/lib/photon_node/executor.ex`, its decisions in
`executor/rules.ex`, its journal in `executor/journal.ex`), the shell
operation processes it owns (`ops.ex`, `ops/shell.ex`), the OS commands
they start, and a stand-in for the hub that follows the hub rules in
`docs/operations.md`. Faults: executor crashes at any point inside any of
its handlers, operation process crashes, abrupt node crashes (commands
survive), node stops (a shell kills its command and leaves the `stopped`
marker, or leaves the `unstarted` marker if it was still waiting to start
one), dropped connections, extra `op.start` pushes, cancels (a shell
leaves the `canceled` marker before a cancel's kill), and commands that
leave background children or never exit.

It replaces `Coordinator.tla`, which modeled one node session's
coordinator with the same shell operations under it. Build step 1 deleted
node sessions, and the operations now belong to the executor, so this spec
keeps the operation-process part of the old one (its actions `OpInit`,
`OpSpawn` (now `OpCkDone`), `OpCancelAck` (now the `:cancel` answer in
`OpCkDone`), `PidLine`, `PortExit`, `OpCancel`, `OpResend`, `Poll`,
`CmdExit`, `BgExit`, `OpCrash`, and the properties `AtMostOnceExec` and
`CallResult`) with the executor as the checkpoint sink in place of the
coordinator. The session parts went with the code. The findings that
spec made about operations (F3, F8, F9, F11, K1) each have a bug config
here, and so do the two this spec found in the code as first built (E1,
K2), both fixed since.

`HubOps.tla` models the protocol end to end, with the executor as one
party that never crashes. This spec opens the executor up: it adds what
`HubOps.md` leaves out, executor-only crashes and operation-process
crashes, and keeps the hub simple.

## How to run

TLC lives at `~/.local/share/tla/tla2tools.jar` (Java 21). From
`specs/tla`:

```sh
java -XX:+UseParallelGC -cp ~/.local/share/tla/tla2tools.jar tlc2.TLC \
  -workers auto -deadlock -lncheck final -metadir /tmp/tlc-Executor/<Cfg> \
  -config <Cfg>.cfg Executor.tla
```

Every config also turns deadlock checking off itself (`CHECK_DEADLOCK
FALSE`): an op that has its result, with the budgets spent, is meant to
stop. `-lncheck final` only matters for configs with `PROPERTIES`.

## What is modeled

One or two ops, each from its own tool call on the hub (its own op ID).

### State and code mapping

| Model | Code |
| --- | --- |
| `jr[c]` | the journal entry `<data_dir>/ops/<id>/op.json`: `st`, the snapshot's status, and `cx`, the `cancel` flag. Snapshots are reduced to their status: `ready`; `awaiting` in phase `process` without a pgid (`proc0`) and with one (`proc1`); `awaiting` in phase `read`; and the terminal `completed`, `failed`, `canceled` |
| `es` | the executor process: `up`, `scan` (`init/1` done, `handle_continue(:scan)` pending), `down` (crashed, the supervisor hasn't restarted it yet) or `off` (the node is down) |
| `monCur[c]`, `downq[c]`, `rst[c]` | the executor's memory: whether it monitors the op's live process, the `:DOWN` messages in its mailbox, and `restarted` |
| `p[c]` | the op's `Ops.Shell` process, if any (the registry allows one): where it is (`init`, in its checkpoint call `ck`, in a report call `rep`, or waiting for messages in `spawning`, `running` or `polling`), the snapshot it holds, the answer to its call, a `:cancel` or `:resend` waiting, its `canceled` flag, and whether its port is open |
| `os[c]` | the command: running or exited, background children left in its group, the `exit`, `pid`, `stopped`, `canceled` and `unstarted` files, how often it was spawned, and a ghost `self` (it exited on its own) |
| `conn`, `h2n`, `n2h` | the `Connection` joined to the hub's channel, and the messages in flight each way, FIFO, lost when the socket drops |
| `hrow`, `hcx`, `hconf`, `hres` | the hub's op row: `open` or `done`, its `cancel` flag, whether the hub has seen a snapshot (`known`), and the result it recorded |

### Actions

| Action | Code |
| --- | --- |
| `NodeRecv` | `Connection.handle_message/4` hands `op.start`, `op.cancel` or `op.ack` to `Executor.start/1`, `cancel/1`, `ack/1`: `start_op/2` with `Rules.on_start/3`, `cancel_op/2`, `ack_op/2` |
| `ExecCheckpoint` | `handle_call({:checkpoint, op})`: `checkpoint_op/2` and `confirm/4` (node rule 4) |
| `ExecReport` | `handle_call({:report, op})`: `report_op/2` and `record/3` (node rule 5) |
| `ExecDown` | `handle_info({:DOWN, ...})`: `down/3`, `exited/3` with `Rules.down/3` |
| `ScanStep` | `handle_continue(:scan)` with `Rules.on_scan/2`, in ID order |
| `ExecCrash`, `ExecRestart` | the executor dies (between handlers, or after any prefix of a handler's effects: the `crash` mode of each step above); `PhotonNode` is `:rest_for_one`, so the `Connection` restarts with it |
| `CallNoproc` | a call made while the executor isn't registered exits at once |
| `NodeCrash`, `NodeStop`, `NodeBoot` | the VM dies abruptly (also after any prefix of a handler's effects: the `node` mode), or stops on purpose (the executor stops first, so a shell waiting in its checkpoint call gets `:ignored` and writes the `unstarted` marker; every other shell's `terminate/2` runs), and starts again |
| `OpInit` | `Shell.handle_continue(:start)`: `prepare/1` removes the leftover files (the `unstarted` and `canceled` markers among them) and asks for the `process` checkpoint; `recover/1` (with a checkpoint for a pgid found in the `pid` file), which checks the `canceled` marker (finishing as canceled, `cancel/1`) and then the `stopped` one before the exit file; `reattach/2`, which starts the command through `prepare/1` when there is no pgid and the `unstarted` marker is there; `finish/2` |
| `OpCkDone` | `start_when_confirmed/2`: `:ok` spawns the command (the wrapper writes its `pid` file), `:cancel` cancels without spawning, `:ignored` writes the `unstarted` marker and stops without spawning |
| `OpReturn` | a report call returns (`:ok`, or `:down` if the executor died), and the shell goes on from where it called |
| `PidLine`, `PortExit`, `OpCancel`, `OpResend`, `Poll` | the `pid` line handler (with `kill_if_canceled/2`), `{:exit_status, _}` (`exited/2` after `kill_group/3`), `:cancel` (the `canceled` marker, then the kill), `:resend`, `:poll` (`poll_recovered/1`) |
| `OpCrash` | a crash of the shell's own code; `terminate/2` kills the group if the port is open, or if the snapshot is still `awaiting` in phase `process` (`proc0` or `proc1`) with a pgid on record in it or in the `pid` file, so a resumed shell kills its command whether or not it has reattached yet. It writes the `stopped` marker first unless the command's exit file is already there. The monitor reports the crash |
| `CmdExit`, `BgExit` | the command (and any background child) exiting; the wrapper writes `exit` |
| `HubStart`, `HubRepush`, `HubCancel`, `HubRecv`, `Join`, `Disconnect` | the hub: a call's row and its `op.start` (hub rules 1 and 2), an online recheck's push (rule 11), a cancel (rule 7), `Machines.snapshot/3` (rules 3 to 6); a join, on which the node pushes `Executor.snapshots/0` and the hub `op.start` or `op.cancel` for its open rows; a dropped socket |

### How a handler is written

Each executor handler is a pure function of the state that returns its
effects in order: journal writes (fsynced before `Journal.write/3`
returns), forwards to the hub (`Link.snapshot/1`), `Ops.add/2` with the
monitor that follows, `Ops.cancel/1`, the reply to an operation's call,
and adding to `restarted`. A normal step applies all of them. A crash step
applies any prefix and then kills the executor (or the node): its
monitors, `restarted` set and mailbox are gone, a call waiting on it
returns `:ignored` or `:down`, and the `Connection` restarts, so the socket
closes and messages in flight are lost. The executor's code is one
GenServer callback per message, so a crash inside one leaves exactly a
prefix of its writes and sends.

An operation process blocks in its calls (`Owner.checkpoint/2` and
`report/2` are calls with no timeout), so it takes no other step until the
executor answers or dies. A crash of the shell's own code can't happen
while it waits in a call, so `OpCrash` is only possible where it runs its
own code.

### Abstractions

- One kind of operation, `shell`. A `view_image` job only reads, and
  running it twice is harmless; `Ops.Job` reports its result in one step.
- Journal writes don't fail, and every entry can be read (node rule 8's
  write failures, held results and unreadable entries are below the
  model). Without a failed write every terminal snapshot the node sends is
  journaled first.
- Output, `op.output`, `fit/2` and the 6 MB budget, the sweep, and
  `Request.operation/2`'s argument checks are left out.
- The hub stand-in records a result for every terminal snapshot on an open
  row, canceled or not, where `Photon.Machines` closes a canceled row
  without its result. Its rules are otherwise those in
  `docs/operations.md`, and its own crashes and commits are
  `HubOps.tla`'s.
- The `Connection` pushes a forwarded snapshot only while joined, at once:
  its mailbox (where forwards wait while it joins) is `HubOps.tla`'s
  `fq`.
- Killing a group is one step. The shell polls the group without blocking
  and postpones the messages that come meanwhile, so each modeled step
  still sees the state it would after a blocking wait.
- The wrapper writes its `pid` file in the same step that spawns the
  command, and records the exit status (143) of a command it outlives when
  the group is killed.
- `prepare/1` removes the `unstarted` marker in the same step that asks
  for the checkpoint. In the code the removal comes first, and the
  journal's directory sync when it stores the checkpoint puts it on disk
  before any spawn. `Journal.forget/2`, which also deletes the marker, is
  left out: nothing reads it after the ack.
- `Registry.lookup/2` can list a process that has just exited; `Ops.add/2`
  checks that it is alive (see "Below the model").

### Faults and fairness

Faults, each bounded by a constant: executor crashes, operation process
crashes, abrupt node crashes, node stops, dropped connections, cancels and
extra `op.start` pushes. Tool calls (`HubStart`) aren't faults but aren't
fair either.

Fairness: the executor handles what it is sent, the supervisor restarts
it, operation processes make progress, the node boots again, the
`Connection` rejoins, and the hub handles what reaches it. `Spec` also
lets commands exit on their own; `SpecUnboundedCommands` doesn't (servers,
`sleep 1e9`), so there only a cancel ends one. Background children need
never exit. Both use one weak-fairness condition on all system actions
(`SysNext`), as `Durable.tla` does: it only rules out stopping while a
system action is enabled, which is weaker than `FairnessFine` (per action),
so what holds under it holds under `SpecFine`. System actions alone can't
loop: each moves an op, a message or a process forward.

## Properties

Safety:

| Name | Meaning |
| --- | --- |
| `AtMostOnceExec` | each op's command is spawned at most once |
| `ResultPhysical` | once the hub has an op's result, nothing of its command (the command or a background child) is running |
| `ResultTruthful` | the result says what happened: `completed` only for a command that exited on its own, canceled or not (before E1 was fixed this clause excepted canceled ops, and `CompletedMeansExited` checked the strict form), `canceled` only if the hub canceled, `failed` only after a fault, never "no record" |

Liveness:

| Name | Meaning |
| --- | --- |
| `CallResult` | every op the hub started gets its result (needs commands to exit) |
| `CancelTakesEffect` | once the hub cancels an op, it gets its result and nothing of its command is left running, even a command that would run forever |
| `ResultsForgotten` | every finished op's journal entry is eventually forgotten (node rule 6) |

## Results

TLC 2.19, Java 21, on the shared 12-core machine, 2026-10-06, rerun after
the E1 and K2 fixes (the `canceled` marker, and `terminate/2` killing any
command on record for a snapshot still awaiting its process): 6 workers,
or 11 for `Executor-two.cfg`. The load average sat between 37 and 50
from other work. Safety is `TypeOK`, `AtMostOnceExec`, `ResultPhysical`
and `ResultTruthful` (now without the exception for canceled ops);
liveness is `CallResult`, `CancelTakesEffect` and `ResultsForgotten`.
`Executor-faults.cfg` now checks `ResultPhysical` too, which K2 kept it
from before. Compared with the run after G1 (`Executor` 371,131,
`-node` and `-cancel` 118,549, `-faults` 4,593,304, `-two` 90,834,364),
the configs with a node crash or stop reach fewer states, since a
resumed shell that crashes or stops now kills its command, and the
configs with a cancel reach a few more, from the marker. `-two` and
`-two-live`, with neither, reach the same counts. A failing config's count is how far TLC got.

| Config | Shape | Checks | Expected | Distinct states | Time |
| --- | --- | --- | --- | --- | --- |
| `Executor.cfg` | 1 op; 1 executor crash, 1 operation process crash, 1 dropped connection, 1 extra `op.start`, 1 cancel; background children | safety, liveness | pass | 374,709 | 1m55s |
| `Executor-node.cfg` | 1 op; 1 node crash, 1 node stop, 1 executor crash, 1 cancel; background children | safety, liveness | pass | 115,637 | 41s |
| `Executor-cancel.cfg` | as `-node`, commands may run forever | safety, `CancelTakesEffect`, `ResultsForgotten` | pass | 115,637 | 31s |
| `Executor-faults.cfg` | 1 op; 2 executor crashes and one of every other fault | safety | pass | 4,403,682 | 2m18s |
| `Executor-two.cfg` | 2 ops; 1 executor crash | safety | pass | 90,834,364 | 17m10s |
| `Executor-two-live.cfg` | 2 ops; 1 cancel | safety, liveness | pass | 258,210 | 2m07s |
| `Executor-bug-double-exec.cfg` | F3 put back; 1 executor crash | `AtMostOnceExec` | fails, 18-state trace | 2,094 | 2s |
| `Executor-bug-cancel-before-pid.cfg` | F8 put back; 1 cancel, commands may run forever | `CancelTakesEffect` | fails, 15 states then stuttering | 321 | 1s |
| `Executor-bug-op-crash.cfg` | F9 put back; 1 operation process crash | `CallResult` | fails, 10 states then stuttering | 81 | 1s |
| `Executor-bug-bg-reattach.cfg` | F11 put back; 1 node crash, background children | `CallResult` | fails, 17 states then stuttering | 1,319 | 2s |
| `Executor-bug-pid-file.cfg` | K1 put back; 1 node crash | `ResultPhysical` | fails, 13-state trace | 729 | 1s |
| `Executor-bug-stopped-marker.cfg` | node rule 10 broken; 1 node stop | `ResultTruthful` | fails, 18-state trace | 966 | 1s |
| `Executor-bug-cancel-marker.cfg` | E1 put back; 1 executor crash, 1 cancel | `ResultTruthful` | fails, 23-state trace | 13,754 | 2s |
| `Executor-bug-orphan-reattached.cfg` | K2 put back (G1's `terminate/2`); 1 node crash, 1 operation process crash | `ResultPhysical` | fails, 13-state trace | 1,494 | 2s |

Each of the two new bug configs differs from the clean code only by its
switch, so its trace also shows the fixed path is reached: with `Bugs =
{}` the same shapes pass (E1's 16,126 states, K2's 2,833).

A failing config stops at its first violation, so its state count is how
far TLC got, and with several workers the trace it reports can differ by
a state or two between runs.

The configs are sized to finish within about 15 minutes (`Executor-two.cfg`
takes a little longer, since G1's marker path adds states, and 17m10s on
this loaded machine). Two ops
interleave freely, so the state space is roughly the square of one op's:
with a cancel or a node crash as well as the executor crash,
`Executor-two.cfg` passed 50M states with its queue still growing after
11 minutes, and two ops with liveness and any fault passed 2.5M states in
11 minutes (liveness checking runs at about 250,000 states a minute
here). So faults are combined on one op, and two ops check the
interactions between entries (the scan, joins and snapshots in ID order)
with one fault for safety and none for liveness.

## Checks that the model reaches what it should

Run once, each as an invariant that should fail, on `Executor-faults.cfg`'s
constants with one executor crash. TLC reached each of these, with a
trace of 5 to 18 states: a `completed`, a `canceled` and a `failed`
result; a `failed` result after an executor crash and no other fault (the
"outcome unknown" case `HubOps.md` describes, reached before G1; on the
merged code it isn't, see "Observations"); a `failed` result after an
operation process crash alone; a `failed` result from the `stopped`
marker; a `completed` result after a node crash or stop; a `canceled`
result for an op that never spawned (the checkpoint answered `:cancel`,
or "canceled before it started"); a `canceled` result after an executor
crash; a reattached command (`polling`); a recovery that found the pgid in
the `pid` file; a restart after a clean exit (`restarted`); a `:DOWN`
ignored because the op was still monitored; a call answered by the
executor's death; and an entry forgotten after its result was recorded.
After G1, two more on the merged code: a resumed shell back in its
checkpoint call with a `proc0` snapshot, which only the `unstarted`
marker's path produces (one executor crash, 9 states), and the marker
written by a node stop while a shell waits in its checkpoint call (one
node stop, 5 states).
`-continue` with all of them at once makes TLC 2.19 throw an
`ArrayIndexOutOfBoundsException`, as it did for `Coordinator-witness.cfg`,
so each ran on its own.

## The bug configs

Each puts back one defect with a switch in `Bugs` and fails on the
property that catches it. The traces are TLC's first counterexample.

### F3. A command spawned before its checkpoint was journaled

`Executor-bug-double-exec.cfg` (`double_exec`), `AtMostOnceExec`, 19
states. Found by `Coordinator.tla`, when a shell sent its `process`
checkpoint and spawned at once. Trace: the op starts and its shell spawns
the command while it reports `proc0`; the executor crashes before it
journals that, so the journal still says `ready`. The shell's reports
return `:down` while the command runs and exits, and the shell stops. The
restarted executor's scan finds `ready` with nothing running it and starts
the op again, which spawns the command a second time.

Fixed (node rule 4): the shell asks for the checkpoint with a call
(`Owner.checkpoint/2`) and spawns only on `:ok`, which the executor sends
after the journal write. `ExecCheckpoint` and `OpCkDone`.

### F8. A cancel that came before the pid line didn't kill the command

`Executor-bug-cancel-before-pid.cfg` (`cancel_before_pid`),
`CancelTakesEffect`, under `SpecUnboundedCommands`, 15 states then
stuttering. The hub cancels just after `op.start`. The command has
spawned, but the wrapper hasn't printed its pid, so `:cancel` only sets
`canceled` (`kill_group(nil)` does nothing). Without the check, the pid
line doesn't kill it either, and a command that never exits runs on with
its op unfinished.

Fixed: `kill_if_canceled/2` kills the group once the pid is known.

### F9. A crashed operation process was never noticed

`Executor-bug-op-crash.cfg` (`unmonitored`), `CallResult`, 5 states then
stuttering. The shell crashes in its `handle_continue`. With no monitor,
nothing fails the op, and its journal says `ready` for good (the hub's
next join or recheck would resume it, but with no disconnect and no
recheck in this config nothing does).

Fixed: the executor monitors every operation process (rule 87), and
`Rules.down/3` fails an op whose process crashed. A clean exit before a
terminal snapshot (the shell stopped because its checkpoint was
`:ignored`) restarts it once.

### F11. A reattached shell waited for background children

`Executor-bug-bg-reattach.cfg` (`poll_order`), `CallResult`, 17 states
then stuttering. The node crashes while the command runs. After boot the
shell finds its pgid in the `pid` file and reattaches. The command exits
and leaves a background child in its group; polling checks the group
before the exit file, so the shell waits on a child that never exits.

Fixed: `poll_recovered/1` checks the exit file first, then kills the
group and finishes.

### K1. A command started just before a crash couldn't be found

`Executor-bug-pid-file.cfg` (`no_pid_file`), `ResultPhysical`, 13 states.
A known gap upstream, which `Coordinator.tla` reported. The node crashes
after the spawn and before the pid line. Recovery from `proc0` finds no
pgid and fails the op ("outcome is unknown"), and the hub records that
while the command runs on.

Fixed: the wrapper writes the command's pid to `pid` as it starts it, and
recovery reads it when the snapshot has no pgid.

### Node rule 10. A stopped node reported a killed command as completed

`Executor-bug-stopped-marker.cfg` (`no_stopped_marker`), `ResultTruthful`,
17 states. New with this spec; node rule 10 was written for it. The node
stops on purpose while the command runs, so the shell's `terminate/2`
kills its group. The wrapper, outside the group, writes exit 143 for it.
After the restart, recovery finds the exit file and reports the command
`completed` with partial output.

Fixed: `terminate/2` writes the `stopped` marker before it kills, and
`recover/1` checks the marker before the exit file and fails the op.

### E1. A command killed by a cancel was reported `completed`

`Executor-bug-cancel-marker.cfg` (`no_cancel_marker`), `ResultTruthful`,
23 states. Found by this spec in the code as first built. The hub cancels
a running command. The shell kills its group, so the wrapper records exit
143, and the shell reports `canceled`. The executor crashes before it
journals that, so the report returns `:down` and the shell stops. The
journal still says `proc1` with `cancel` set. The restarted executor
resumes the op and follows `Ops.add/2` with `Ops.cancel/1` (node rule 2),
but the new shell runs `recover/1` in its `handle_continue` before it
handles `:cancel`. Recovery finds the exit file and reports the command
`completed`, exit code 143, with whatever output it wrote. An abrupt node
crash at the same point does the same. It was low severity: every cancel
comes from a commit that ends the call, and `Photon.Machines` closes a
canceled row without showing its result, so the hub saw it only if that
commit rolled back.

Fixed: the shell writes a `canceled` marker before a cancel's kill
(`handle_info(:cancel, _)`, and `cancel/1` while the snapshot is
`awaiting` in phase `process`), and `recover/1` checks it before the
`stopped` marker and the exit file and finishes the op as canceled. A
fresh start removes a stale marker, and `Journal.forget/2` deletes it.
`ResultTruthful` no longer excepts canceled ops from its first clause.

### K2. A shell that crashed before it reattached left its command running

`Executor-bug-orphan-reattached.cfg` (`kill_reattached_only`),
`ResultPhysical`, 13 states. Found by this spec; `Coordinator.tla` had
the same gap, unreported (its op-crash configs didn't check
`IdlePhysical`). After a node crash, a shell resumed from `proc0` or
`proc1` owns no port: it waits for a command the previous VM started. Its
`terminate/2` killed the group only when the port was open or, as G1
built it, once `reattach/2` had found the group alive (the `reattached`
flag). A crash in `recover/1` before that point killed nothing, which is
the trace: the node crashes after the spawn, the resumed shell crashes in
its `handle_continue` (`OpCrash` in `init`), the executor fails the op
("the operation process exited"), the hub records it, and the command
runs on with nothing watching it. Before G1 a crash while polling did the
same. It was low severity: it took a node crash and then a crash in the
shell's own code.

Fixed: `terminate/2` kills the recorded process group (from the snapshot,
or the `pid` file) whenever the port is open or the snapshot is still
`awaiting` in phase `process`, after the `stopped` marker. The `reattached`
flag is gone. The marker is left out when the command's exit file is
already there: the command has exited, the kill is only for children it
left, and its exit status stands.

## Findings

This spec found two gaps in the code as first built, E1 and K2. Both are
fixed, and each is a bug config above.

### Observations (not traced)

- Before G1, a node stopped on purpose didn't kill a reattached command:
  its shell had no port, so `terminate/2` wrote no marker and killed
  nothing, and the next start reattached to it again. Since G1 it is
  killed and reported as stopped (node rule 10), like a command the
  stopping VM started. Since K2 was fixed, so is a command whose resumed
  shell is stopped while still in `recover/1`, before it reattaches
  (before, it was left running for the next start, which was harmless).
- An executor crash after it journals a `process` checkpoint and before it
  answers leaves a shell that stops without spawning. Before G1 the
  resumed op failed with "outcome is unknown because process start was
  not recorded" (`HubOps.md` describes it, from the hub-plus-node test).
  Since G1 the shell writes the `unstarted` marker first, and the resumed
  shell starts the command through the checkpoint again (TLC reaches a
  shell in its checkpoint call holding a `proc0` snapshot after one
  executor crash, which only that path produces). With one executor crash
  and no other fault, no op ends `failed` now (a temporary invariant held
  over 135,837 states with one executor crash, a dropped connection, a
  cancel, a re-push and background children); with two executor crashes,
  the restart-once rule can still fail it. A node stop while a shell waits in its checkpoint call
  writes the marker too (reached in 5 states).

### Below the model

`Registry.lookup/2` returns a registered process until the registry has
handled its exit. `Ops.add/2` checks that a listed process is alive before
it asks it to resend, and otherwise starts a new one, and `Rules.down/3`
treats a `:noproc` exit like a clean one (restarted once). The model has
no registry (an op's process is gone the moment it exits), so this rests
on the ExUnit tests (`shell_test.exs`, `executor_test.exs` and
`rules_test.exs`, which call it node-op-stale-registry).

## TLC note

TLC evaluates operator arguments and LET definitions lazily and doesn't
cache them while it checks ENABLED and temporal formulas. A handler's
effects are folded over a record of the world, so every operator in the
fold binds its state argument first with
`Strict(x, F) == CHOOSE r \in {F(v) : v \in {x}} : TRUE`, and the steps
bind the fold's result with `\E W \in {...}`. That made the liveness
configs about three and a half times faster (`Executor.cfg` went from
4m21s to 1m13s with the same state count). `Coordinator.tla` did the
same.
