# Executor: the node's executor, journal and operation processes

`Executor.tla` models how a node runs the hub's operations: the executor
(`apps/node/lib/photon_node/executor.ex`, its decisions in
`executor/rules.ex`, its journal in `executor/journal.ex`), the shell
operation processes it owns (`ops.ex`, `ops/shell.ex`), the OS commands
they start, and a stand-in for the hub that follows the hub rules of
section 2.3 of `docs/plans/step-1-machine-tools.md`. Faults: executor
crashes at any point inside any of its handlers, operation process
crashes, abrupt node crashes (commands survive), node stops (a shell kills
its command and leaves the `stopped` marker), dropped connections, extra
`op.start` pushes, and commands that leave background children or never
exit.

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
here.

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
| `os[c]` | the command: running or exited, background children left in its group, the `exit`, `pid` and `stopped` files, how often it was spawned, and a ghost `self` (it exited on its own) |
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
| `NodeCrash`, `NodeStop`, `NodeBoot` | the VM dies abruptly (also after any prefix of a handler's effects: the `node` mode), or stops on purpose (every shell's `terminate/2` runs), and starts again |
| `OpInit` | `Shell.handle_continue(:start)`: `prepare/1` asks for the `process` checkpoint; `recover/1` (with a checkpoint for a pgid found in the `pid` file), `reattach/2`; `finish/2` |
| `OpCkDone` | `start_when_confirmed/2`: `:ok` spawns the command (the wrapper writes its `pid` file), `:cancel` cancels without spawning, `:ignored` stops without spawning |
| `OpReturn` | a report call returns (`:ok`, or `:down` if the executor died), and the shell goes on from where it called |
| `PidLine`, `PortExit`, `OpCancel`, `OpResend`, `Poll` | the `pid` line handler (with `kill_if_canceled/2`), `{:exit_status, _}` (`exited/2` after `kill_group/3`), `:cancel`, `:resend`, `:poll` (`poll_recovered/1`) |
| `OpCrash` | a crash of the shell's own code; `terminate/2` writes the `stopped` marker and kills the group if the port is open; the monitor reports it |
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
- The hub stand-in records a result for every terminal snapshot on an
  open row, canceled or not, where `Photon.Machines` closes a canceled
  row without its result. Its rules are otherwise the plan's, and its own
  crashes and commits are `HubOps.tla`'s.
- The `Connection` pushes a forwarded snapshot only while joined, at once:
  its mailbox (where forwards wait while it joins) is `HubOps.tla`'s
  `fq`.
- Killing a group is one step. The shell polls the group without blocking
  and postpones the messages that come meanwhile, so each modeled step
  still sees the state it would after a blocking wait.
- The wrapper writes its `pid` file in the same step that spawns the
  command, and records the exit status (143) of a command it outlives when
  the group is killed.
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
| `ResultTruthful` | the result says what happened: `completed` only for a command that exited on its own (or for an op the hub canceled, whose result the hub doesn't show; see E1), `canceled` only if the hub canceled, `failed` only after a fault, never "no record" |
| `CompletedMeansExited` | `ResultTruthful`'s first clause without the exception for canceled ops (E1) |

Liveness:

| Name | Meaning |
| --- | --- |
| `CallResult` | every op the hub started gets its result (needs commands to exit) |
| `CancelTakesEffect` | once the hub cancels an op, it gets its result and nothing of its command is left running, even a command that would run forever |
| `ResultsForgotten` | every finished op's journal entry is eventually forgotten (node rule 6) |

## Results

TLC 2.19, Java 21, on the shared 12-core machine, 2026-10-05: 6 workers,
or 11 for the two-op configs. The load average sat around 38 from other
work, though the CPUs were mostly idle. Safety is `TypeOK`,
`AtMostOnceExec`, `ResultPhysical` and `ResultTruthful`; liveness is
`CallResult`, `CancelTakesEffect` and `ResultsForgotten`.

| Config | Shape | Checks | Expected | Distinct states | Time |
| --- | --- | --- | --- | --- | --- |
| `Executor.cfg` | 1 op; 1 executor crash, 1 operation process crash, 1 dropped connection, 1 extra `op.start`, 1 cancel; background children | safety, liveness | pass | 329,968 | 1m24s |
| `Executor-node.cfg` | 1 op; 1 node crash, 1 node stop, 1 executor crash, 1 cancel; background children | safety, liveness | pass | 108,598 | 33s |
| `Executor-cancel.cfg` | as `-node`, commands may run forever | safety, `CancelTakesEffect`, `ResultsForgotten` | pass | 108,598 | 24s |
| `Executor-faults.cfg` | 1 op; 2 executor crashes and one of every other fault | `TypeOK`, `AtMostOnceExec`, `ResultTruthful` | pass | 3,979,767 | 2m15s |
| `Executor-two.cfg` | 2 ops; 1 executor crash | safety | pass | 71,796,716 | 13m10s |
| `Executor-two-live.cfg` | 2 ops; 1 cancel | safety, liveness | pass | 258,210 | 1m20s |
| `Executor-bug-double-exec.cfg` | F3 put back; 1 executor crash | `AtMostOnceExec` | fails, 19-state trace | 2,082 | 2s |
| `Executor-bug-cancel-before-pid.cfg` | F8 put back; 1 cancel, commands may run forever | `CancelTakesEffect` | fails, 15 states then stuttering | 321 | 2s |
| `Executor-bug-op-crash.cfg` | F9 put back; 1 operation process crash | `CallResult` | fails, 5 states then stuttering | 81 | 2s |
| `Executor-bug-bg-reattach.cfg` | F11 put back; 1 node crash, background children | `CallResult` | fails, 17 states then stuttering | 1,319 | 3s |
| `Executor-bug-pid-file.cfg` | K1 put back; 1 node crash | `ResultPhysical` | fails, 13-state trace | 661 | 2s |
| `Executor-bug-stopped-marker.cfg` | node rule 10 broken; 1 node stop | `ResultTruthful` | fails, 17-state trace | 921 | 2s |
| `Executor-known-cancel-completed.cfg` | E1, the code as it is; 1 executor crash, 1 cancel | `CompletedMeansExited` | fails, 23-state trace | 12,075 | 3s |
| `Executor-known-orphan-reattached.cfg` | K2, the code as it is; 1 node crash, 1 operation process crash | `ResultPhysical` | fails, 13-state trace | 1,324 | 2s |

A failing config stops at its first violation, so its state count is how
far TLC got, and with several workers the trace it reports can differ by
a state or two between runs.

The configs are sized to finish within about 15 minutes. Two ops
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
"outcome unknown" case `HubOps.md` describes); a `failed` result after an
operation process crash alone; a `failed` result from the `stopped`
marker; a `completed` result after a node crash or stop; a `canceled`
result for an op that never spawned (the checkpoint answered `:cancel`,
or "canceled before it started"); a `canceled` result after an executor
crash; a reattached command (`polling`); a recovery that found the pgid in
the `pid` file; a restart after a clean exit (`restarted`); a `:DOWN`
ignored because the op was still monitored; a call answered by the
executor's death; and an entry forgotten after its result was recorded.
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
17 states. New with this spec; the plan's node rule 10 was written for it.
The node stops on purpose while the command runs, so the shell's
`terminate/2` kills its group. The wrapper, outside the group, writes exit
143 for it. After the restart, recovery finds the exit file and reports
the command `completed` with partial output.

Fixed: `terminate/2` writes the `stopped` marker before it kills, and
`recover/1` checks the marker before the exit file and fails the op.

## Findings

### E1. A command killed by a cancel can be reported `completed`

`Executor-known-cancel-completed.cfg`, `CompletedMeansExited`, 23 states.
Found by this spec, against the code as it is; not fixed. The hub cancels
a running command. The shell kills its group, so the wrapper records exit
143, and the shell reports `canceled`. The executor crashes before it
journals that, so the report returns `:down` and the shell stops. The
journal still says `proc1` with `cancel` set. The restarted executor
resumes the op and follows `Ops.add/2` with `Ops.cancel/1` (node rule 2),
but the new shell runs `recover/1` in its `handle_continue` before it
handles `:cancel`. Recovery finds the exit file and reports the command
`completed`, exit code 143, with whatever output it wrote. An abrupt node
crash at the same point does the same.

Severity: low. Every cancel comes from a commit that ends the call, and
`Photon.Machines` closes a canceled row without showing its result. The
model sees it only if that commit rolled back (a hub crash: `HubOps.md`
traces how a rerun then receives the node's snapshot), and even then the
result says exit code 143. Two ways to fix it, both on the node: let
recovery take the journal's `cancel` flag (start the resumed shell
canceled, so a found exit file reports `canceled`), or have the shell
write a marker before a cancel's kill, as it does before a stop's.
`ResultTruthful` allows this case, so the clean configs pass; the known
config checks the strict form.

### K2. A crashed shell that didn't start its command leaves it running

`Executor-known-orphan-reattached.cfg`, `ResultPhysical`, 13 states. Not
fixed. After a node crash, a shell resumed from `proc0` or `proc1` doesn't
own a port: it reattaches to a command the previous VM started. If that
shell crashes (in `recover/1` or while polling, for example when
`System.cmd/2` raises), its `terminate/2` kills nothing, since it only
kills when the port is open. The executor fails the op ("the operation
process exited"), the hub records it, and the command runs on with nothing
watching it. `Coordinator.tla` had the same gap, unreported (its op-crash
configs didn't check `IdlePhysical`).

Severity: low; it takes a node crash and then a crash in the shell's own
code. A fix: `terminate/2` kills the recorded pgid whenever the snapshot
has one, not only while the port is open.

### Observations (not traced)

- A node stopped on purpose doesn't kill a reattached command: its shell
  has no port, so `terminate/2` writes no marker and kills nothing. The
  command survives the stop, and the next start reattaches to it again.
  Nothing goes wrong, but node rule 10's "a node that stops on purpose
  kills its running commands" holds only for commands the stopping VM
  started.
- An executor crash after it journals a `process` checkpoint and before it
  answers leaves a shell that stops without spawning, and the resumed op
  fails with "outcome is unknown because process start was not recorded"
  (`HubOps.md` describes it, from the hub-plus-node test). The command
  never ran, and the result says it may not have. `ResultTruthful` allows
  `failed` after any fault.

### Below the model

`Registry.lookup/2` returns a registered process until the registry has
handled its exit. `Ops.add/2` checks that a listed process is alive before
it asks it to resend, and otherwise starts a new one, and `Rules.down/3`
treats a `:noproc` exit like a clean one (restarted once). The model has
no registry (an op's process is gone the moment it exits), so this rests
on the ExUnit tests (`shell_test.exs`, `executor_test.exs`, `rules_test.exs`;
node-op-stale-registry in `docs/verification.md`).

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
