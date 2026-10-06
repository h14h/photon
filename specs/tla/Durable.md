# Durable: the hub's durable harness and its machine calls

`Durable.tla` models `Photon.Durable` (Store, Tx, Runtime, Scheduler,
Generation, ToolTask) with the tool calls a conversation makes: a machine
call (`shell` or `view_image`, both `Photon.MachineTools.Call`), a plain
tool that isn't safe to rerun, and the routine task behind a schedule,
which may repeat and which the owner may edit or delete. Faults are hub
crashes, Scheduler crashes, step crashes, a machine call's own code
raising, and user Stops. The machine's result can arrive at any time. It
follows the code after build step 1, and for schedules step 3's plan
(`docs/plans/step-3-skills-and-schedules.md`, sections 3.3 and 3.4),
written before that code: `schedules/routine.ex` (`Routine`, moved from
`assistant/routine.ex`) and `schedules.ex` (`Schedules.update/3`,
`delete/1`). See "What changed in build step 3".

The first version modeled the harness with the assistant's node work
(`run_on_node`, `NodeWork`, `NodeWatch`) and found ten bugs (F1 to F10
below), all fixed in the code. Modeling the first fix for F10 found a flaw
in it (F10b), which is fixed too. Build step 1 replaced node work with
machine calls, and PR B deleted node sessions, so the spec now models the
machine call in its place (see "What changed in build step 1"). Build
step 3 added repeating routines and the owner's edits and deletes (see
"What changed in build step 3"); TLC found no problem in the plan's
rules. Every config is expected to finish with no error, except the two
`Durable-bug-*` configs, which put a defect back and must fail.
`docs/verification.md` lists the ExUnit regression test for each
finding.

Paths below are relative to `apps/hub/lib/photon/`.

## What is modeled

One conversation (every property is per conversation; other conversations
only share the commit line and the Scheduler, and the model already
interleaves those freely).

| Spec variable | Code |
|---|---|
| `task` | `tasks` table (`durable/task_record.ex`): status, phase, runs, abort_requested, owner, background, waiting (`on`/`signal`/`until`), checkpoint (`submissions`, `rounds`, and a machine call's `"offline_since"`, `off`); `tok` stands for the `updated_at` a step's start wrote |
| `sub` | `submissions` table (`durable/submission.ex`): status, mode, insertion order |
| `row`, `rcx` | a machine call's row in `machine_ops` (`machines/op.ex`): `open`, `finished` or `closed`, and its `cancel` flag |
| `signal` | `signals` table, one per op (`"op:" <> op_id`, `Machines.signal_key/1`) |
| `toolResults`, `orphanCalls` | the `tool_result` and `assistant` entries that matter for the properties |
| `claims`, `opResult` | ghosts: how often a finished row's result was taken into a tool result, and whether the call's result is its op's |
| `steps`, `inc` | step processes under `Durable.TaskSupervisor`, and which Scheduler incarnation started them |
| `untilPassed`, `rechecks` | wall clock relative to each waiting task's `until`, and how often a machine call has parked again |
| `carrier` | the schedule's row in `schedules` (`schedules/schedule.ex`), reduced to the routine its `task_id` names; `"none"` once the row is deleted |
| `task[r].fired` | a routine's checkpoint `"runs"`: how often it has fired |
| `fires`, `retired` | firing commits per routine (with `Target = "thread"`, the threads it started), and whether an edit or delete replaced it |
| `lateFire`, `dupFire` | ghosts: a fire step's commit landed after its routine was retired; two firing commits landed for one routine and checkpoint |

Ids are fixed so the state space stays small. Tool task `t1`'s op is keyed
by `t1` too, since the op ID is derived from the task ID
(`Wait.op_id/1`). A routine `r1`'s `k`-th firing posts the submission
`rs_r1_k` (the code's request ID is `"schedule:<id>:<task id>:<runs>"`,
with `runs = k - 1`). `Routines` holds the routine the schedule starts
with (at most one), and `Spares` the routines an edit may create.
Generations `g1, g2, ...` are allocated as `submit_tx` and
`continue_inbox` create them.

The machine is reduced to what the harness sees of it: the row, its
cancel flag and its signal. Pushes, the channel, the websocket and the
node are left to `HubOps.tla`, which models the protocol end to end, and
`Executor.tla`, which models the node.

### Actions and the code they follow

Every `Store.commit` is one atomic action. Work a step does outside a
commit (reads, `Machines.start/1`, which is a Store commit of its own, and
model calls) is its own action, so other commits can land in between.

The decisions the actions model sit in pure modules: the scheduler's in
`durable/policy.ex` (`Policy`), a generation's in `durable/turn.ex`
(`Turn`), a tool call's in `durable/tool_call.ex` (`ToolCall`), the inbox's
in `durable/inbox.ex` (`Inbox`), a machine call's waiting in
`machine_tools/wait.ex` (`Wait`) and its row's in `machines/rules.ex`
(`Rules`). The table names both the boundary function and the rule it
applies.

| Action | Code |
|---|---|
| `UserSubmit` | `Durable.submit/submit_tx` with `Inbox.submit_action/3`: request-id dedupe, busy means queued, idle means placed plus a new generation |
| `UserAbort` | `Assistant.stop` -> `Durable.abort/2`: withdraw the user's queued input (scheduled prompts stay, `Submission.background?/1`), `Tx.request_abort` the active run. This is Blip's Stop; a thread's (`Threads.stop/1`) also withdraws scheduled prompts, which is the withdraw of any queued input |
| `SchedStart` | `Scheduler.start_pending`/`start` (`Policy.start_action/4`, `startable?/1`, `start/1`): pending to running, `runs + 1`, a new `updated_at` (`tok`), spawn the step |
| `SchedWake` | `Scheduler.wake_waiting`, `wake?/2` and `fail_fast/2`, with `Policy.wakeable?/1`, `wake?/3` (and its `on_ready?/3`) and `fail_fast_aborts/2` |
| `SchedKill`, `SchedAbort` | `Scheduler.stop_aborted`: `terminate_child` for `Policy.steps_to_kill/2`, then abort bottom-up (`Policy.ready_to_abort/1`, `abort_tx/2` with `Policy.abort?/1`) with `on_abort`, then `Durable.continue_inbox/2` for a run |
| `SchedExit` | step result or `:DOWN`: a task still `running` and not marked for abort (`Policy.failable?/1`) fails through `fail/2` with `on_fail`, then `continue_inbox` for a run |
| `GenRequest` | `Generation.step("request")` with `answered/4` and `follow/5` on `Turn.outcome/2`: answer and continue with the inbox, tool calls, too many rounds (a `tool_result` per stored call, `Turn.not_run/1`, then the inbox), model error (then the inbox) |
| `GenAfterTools` | `Generation.step("after_tools")` (`Turn.after_tools/2`) |
| `MStart` | `Call.execute/3` up to `Machines.start/1`: its own Store commit, which inserts the row (`on_conflict: :nothing`) only while the task is unfinished and not marked for abort (`Rules.insert?/2`, hub rule 9), else `{:error, :stopped}` and an error result |
| `MPark` | the `{:wait, %{"signal" => "op:<id>", "until" => ...}, state}` transition (`Call.park/4`, `Wait.first/3`, `ToolCall.park/2`), with `offline_since` if the machine is offline |
| `MResume` | `Call.resume/2`: `Machines.op_state/1`, and for an open row whether the machine is online, then `Wait.next/4`: claim, park again, or give up |
| `MRepark` | the `{:wait, ...}` transition of a parked call checked again (after `Machines.repush/1` when online, hub rule 11) |
| `MClaim` | `{:commit, fun}` from `resume/2`: `Machines.claim_tx/2` or `abandon_tx/2` inside the commit that records the result. A finished row is closed and its result returned (hub rule 8); otherwise the result is an error and the row is canceled as `cancel_tx/2` does (hub rules 7 and 10) |
| `PlainRun`, `ToolFinish` | a tool with the default `replay :unsafe` (a rerun after a crash reports "interrupted": `ToolCall.plan/3`); `ToolTask.finish`. A machine call's error result (`Call.fail/2`) and a rescued raise (`ToolTask.raised/3`) run `cancel_tx/2` in that commit |
| `RoutineStart` | `Routine.step("start")`: `first_wait/1` |
| `RoutineFire` | `Routine.step("fire")`: one `Runtime.commit` that reads the row, applies `Rules.fire/2`, posts `RS(r, k)` (`Target = "conv"`: `Durable.submit_tx/4`, through `Threads.send_tx/4` for a thread) or starts a thread (`Target = "thread"`: `Threads.start_tx/4`, counted in `fires`), records the outcome on the row, announces, and returns `after_fire/2`: wait again while `fired < MaxFires`, else `{:done, ...}`. A row that is gone finishes the task and writes nothing (`{:done, %{"gone" => true}}`). `BugFireIgnoresAbort` drops the abort mark from this commit's fence |
| `OwnerEdit` | `Schedules.update/3`: one commit that marks the row's task for abort (`Tx.request_abort/3` with `background: true`), arms a new routine (pending, phase `"start"`) and names it on the row. `BugEditKeepsOld` skips the mark |
| `OwnerDelete` | `Schedules.delete/1` (and Blip's `cancel_schedule`, `delete_tx/3`): one commit that marks the task for abort and deletes the row |
| `OpFinish` | the machine's terminal snapshot: `Machines.snapshot/3` with `Rules.on_snapshot/3` in one Store commit, so an open row becomes `finished` (or `closed` if it was canceled) and the signal fires together (hub rule 4) |
| `Tick` | a waiting task's deadline passes |

`Runtime.commit` is "apply everything, or nothing if the task finished, was
marked for abort, or is not the start this step belongs to"
(`Tx.transition/4` with the started task; `Ignored(st)`). `Tx.finish`
aborts live foreground children. The tool hooks run in the commit that ends
the call: `ToolTask.on_abort`/`on_fail` call the tool's `on_interrupt/2`,
which for a machine call is `cancel_tx/2` (`OnAbortRow`): an open row gets
`cancel`, a finished one is closed and its result dropped.

### Faults

* `HubCrash`: the BEAM dies between any two actions. Steps vanish; the DB
  stays. On boot `Scheduler.init` puts running tasks back to pending, so a
  machine call reruns `execute/2` (it is `replay: :safe`) or `resume/2`.
* `SchedCrash`: only the Scheduler process dies and its supervisor
  (`Photon.Durable.Supervisor`, `:one_for_one`) restarts it. The step
  processes live under a separate `Task.Supervisor` started with
  `async_nolink`, so old steps keep running while `init` resets their tasks
  to pending; their commits are fenced out. `Machines.start/1`'s commit
  isn't the step's, so the fence doesn't cover it; hub rule 9 does.
* `StepCrash`: a step process exits abnormally at any point before its last
  commit, or a machine call's own code raises (in `execute/2`, `resume/2`,
  or between `Machines.start/1` and the park). `ToolTask` rescues a raise
  and records an error result whose commit runs `on_interrupt/2`.
* `UserAbort`: Stop at any time.
* `OwnerEdit`, `OwnerDelete`: the owner edits or deletes the schedule at
  any time, between any two commits, so also while a fire step is
  running, before or after a hub crash or a Scheduler restart.
* The machine may finish an op any time after its row exists, and a check
  may find it offline (`MachineOffline`).

Message loss and the node's side are `HubOps.tla`'s and `Executor.tla`'s.

### Abstractions and why they are sound

* The Scheduler's reconcile pass is split into per-task actions that can
  happen in any order, interleaved with step commits. Each of its commits
  re-reads the task, and the one stale input it keeps (the `blocked` set in
  `stop_aborted`) only shrinks for a task already marked for abort. The
  split allows every real order plus some extra ones, which can't hide a
  safety violation.
* A model request has no side effects before its commit, so the model's
  answer is chosen at commit time.
* A step whose commit moved its task out of `running` is dropped right
  away; one that returns while its task is still `running` stays until
  `SchedExit` handles it.
* The fence: in the code, `Tx.transition/4` compares the task's
  `updated_at` with the one the step started with. While a step runs, only
  an abort request changes its task (and then the transition is ignored
  anyway), so `tok` (bumped at each start) captures exactly that.
* Time is abstract. A parked machine call may wake at any moment its
  `until` has passed, and a call that saw the machine offline at an earlier
  check may give up at any later offline check. That is how the 10-minute
  offline limit looks from here. `MaxRechecks` bounds how often a call's
  `until` may pass (each start bumps `tok`, so unbounded rechecks would make
  the state space infinite); after that it wakes only on its signal.
* The machine's online state isn't a variable: each check reads it
  afresh, online or offline, which allows every pattern of flapping.
* `resume/2` reads the row before its commit, and a call that stays parked
  doesn't read it again; only the claim and the give-up read it inside
  their commits. `HubOps.md` ("The code against the spec") explains why a
  park on a row that finished meanwhile is harmless: the signal wakes the
  call at once.
* A machine call's error results are one action (`ToolFinish` from
  `fin_err`): "stopped before it reached", "already delivered", "no
  record", and a rescued raise all record an error and run `cancel_tx/2`,
  and differ only in their text. Unknown and outdated machines (an error
  before the row exists) are left out; they are the same with no row.
  Since step 2, a parked call whose machine has come back outdated ends
  the same way (an error and `cancel_tx/2`), so it is this action too.
* `when_busy: "reject"`, `withdraw/1`, documents, entry ordering,
  PubSub, live events and `on_fail/3` returning `:retry` are left out.
  Nothing returns `:retry` since `NodeWatch` was deleted, though
  `Policy.after_failure/1` still supports it. No task kind waits with
  `fail_fast`; `GenPolicy` lets the generation use it as a what-if.
* Schedules: one schedule, reduced to the routine its row names. Times
  aren't modeled, so `Rules.arm/4`'s minute of grace, `fired_through/3`
  and `next_after/3` (which time a new or edited routine waits for, and
  that an edit neither skips nor repeats a slot) are checked by
  `test/core/schedules/rules_test.exs`, not here. A repeating routine is
  bounded by `MaxFires`, after which it finishes like a one-off. Consent
  and the overlap rules (`Rules.fire/2`, plan section 3.5) are decisions
  inside the firing commit over committed state, so they only choose
  between posting and skipping; the model always posts, which allows
  more behaviors. The row's `last_*` columns, `Routine.on_fail/3` (which
  records `"failed"` on the row in the commit that fails the task) and
  the announcements write nothing the properties read. Run now
  (`Schedules.run_now/1`) is one commit that submits with a fresh request
  ID and doesn't touch the task, like `UserSubmit` of background input.
  An edit that keeps a one-off's time after it fired arms nothing
  (`arm/4` says `:finished`) and changes nothing modeled, so it is left
  out. An edit that makes a repeating schedule a one-off at the slot it
  just fired also arms nothing, but its old routine is still live: it is
  marked for abort and the row names no routine. On the modeled
  variables that is `OwnerDelete`'s step (the row's columns aren't
  modeled), so `Durable-schedule.cfg`'s `OneCarrier` and
  `NoFireAfterRetire` cover it through that action, and
  `Durable-schedule-retire-live.cfg` (added with this case) checks that
  a routine retired with no replacement ends `aborted`. The spec didn't
  change. Every other edit replaces the routine.

### Fairness

The Scheduler reconciles after every commit that touches tasks or signals,
after every step result or `:DOWN`, and on its timer, so its actions are
weakly fair. Steps keep running, and time passes. An op eventually ends on
its machine (`OpFinish`): the command finishes, or is canceled, once the
machine is back. A running command has no timeout, so without that
assumption a call may wait for good, as designed. The user, the owner's
edits and deletes, and faults get no fairness. The crash budgets are
finite.

`FairnessFine` states that per action and per task. `Spec` uses one
weak-fairness condition on all system actions (`SysNext`). That is weaker,
so a liveness property that holds under `Spec` holds under `SpecFine`, and
TLC checks it much faster.

## Properties

Safety (invariants):

| Name | Meaning |
|---|---|
| `AtMostOneActiveRun` | at most one non-background, conversation-owned, unfinished task |
| `ToolResultIffFinished` | a tool task has no `tool_result` while live and exactly one once finished |
| `NoOrphanCalls` | every tool call in an `assistant` entry got a tool task or a result |
| `AbortedHasNoLiveFgChildren` | an aborted task has no live foreground children |
| `AbortEndsAborted` | a task marked for abort ends `aborted` (through `on_abort`), not `failed` |
| `UnsafeAtMostOnce` | an unsafe tool never executes twice |
| `PlacedTracked` | every placed submission is in the checkpoint of a live generation, which will settle it |
| `OneResultPerCall` | a machine call's result is recorded once, and when it is its op's result, the row was claimed in that commit and is closed |
| `ClaimedOnce` | a finished op's result reaches at most one tool result |
| `NoOpenRowAfterDone` | once a call has ended, however it ended, its row is not open without `cancel`, so nothing may still start its op |
| `BackgroundNotWithdrawn` | Blip's Stop never withdraws a scheduled prompt (`RS(r, k)`); a thread's Stop does, by design (plan section 3.7) |
| `OneCarrier` | at most one routine is live and not marked for abort, and it is the one the row names: an edit or delete never leaves the old timer running beside the new one |
| `NoFireAfterRetire` | no fire step's commit lands for a routine after the commit that retired it (an edit or delete), whether it would post, start a thread, or find the row gone |
| `FireOncePerSlot` | no two firing commits for the same routine and checkpoint, across hub crashes, Scheduler restarts and step crashes; with `Target = "thread"` there is no request ID to fall back on |

Liveness:

| Name | Meaning |
|---|---|
| `PlacedSettles` | placed input eventually becomes `done` or `unanswered` |
| `QueuedNotStranded` | queued input eventually leaves the inbox |
| `ToolTasksFinish` | every tool task finishes |
| `NoRunningForever` | no task stays `running` forever (after crashes) |
| `AbortCompletes` | a task marked for abort finishes |
| `FinishedLeavesNoLiveWork` | a finished task's foreground children all finish |
| `RowsClose` | every op row eventually closes, so no result (up to 5 MB for an image) is kept for good |
| `RetiredEnds` | a routine an edit or delete retired while it was live ends `aborted` |

## How to run

```sh
cd specs/tla
java -XX:+UseParallelGC -cp ~/.local/share/tla/tla2tools.jar tlc2.TLC -workers auto -deadlock \
  -metadir /tmp/tlc-Durable -config Durable.cfg Durable.tla
```

Swap `Durable.cfg` for any variant below, and add `-lncheck final` for
configs with `PROPERTIES`. `-deadlock` turns off deadlock checking: a
conversation that has answered everything is supposed to stop. The
`Durable-bug-*` configs are expected to fail; run them with `-workers 1`
to get the traces below (with more workers TLC may report another trace
of the same length first).

## Results

TLC 2.19, Java 21, 6 workers on the shared 12-core machine, 2026-10-05,
for the configs before step 3. Every config: no error. "Safety set" is
`TypeOK`, `AtMostOneActiveRun`, `ToolResultIffFinished`,
`AbortedHasNoLiveFgChildren`, `UnsafeAtMostOnce`, `PlacedTracked`,
`NoOrphanCalls`, `AbortEndsAborted`, `OneResultPerCall`, `ClaimedOnce` and
`NoOpenRowAfterDone`; the schedule configs add `OneCarrier`,
`NoFireAfterRetire`, `FireOncePerSlot` and `BackgroundNotWithdrawn`.

On 2026-10-06 (step 3) all 15 older configs were rerun with the new
constants at their old values, 4 workers, with the machine's load
average around 40 from other work: each passed with exactly the distinct
state count below, the slowest being `Durable-parallel.cfg` (1m10s). The
step 3 configs ran the same day, under the same load:

| Config | Shape | Checks | Distinct states | Time |
|---|---|---|---|---|
| `Durable.cfg` | 2 user inputs, 1 tool call (machine or unsafe plain), 2 rounds, model errors, machine may be offline, 1 hub crash, 1 step crash, 1 Stop | safety set | 791,160 | 17s |
| `Durable-parallel.cfg` | 1 user input, 2 tool calls in one response, model errors, machine may be offline, 1 hub crash, 1 step crash, 1 Stop | safety set | 1,898,838 | 46s |
| `Durable-routine.cfg` | 1 user input, 1 machine call, a routine firing at any time, model errors, machine may be offline, 1 hub crash, 1 step crash, 1 Stop | safety set, `BackgroundNotWithdrawn` | 862,006 | 23s |
| `Durable-live.cfg` | 1 user input, 1 tool call, model errors, machine may be offline, 1 hub crash, 1 step crash, 1 Stop | `PlacedSettles` `ToolTasksFinish` `NoRunningForever` `AbortCompletes` `FinishedLeavesNoLiveWork` `QueuedNotStranded` `RowsClose` | 20,218 | 14s |
| `Durable-schedcrash-ok.cfg` | 1 user input, 1 tool call, model errors, 1 Scheduler crash, 1 hub crash, 1 Stop | safety set | 27,702 | 4s |
| `Durable-offline.cfg` | 1 machine call, machine may be offline, 2 rechecks, 1 hub crash, 1 Stop | `OneResultPerCall` `ClaimedOnce` `ToolResultIffFinished` `NoOpenRowAfterDone` `AbortEndsAborted`; `ToolTasksFinish` `RowsClose` `AbortCompletes` | 8,496 | 5s |
| `Durable-double.cfg` | F1 rewritten: 1 machine call, machine may be offline, 2 rechecks, no faults | `OneResultPerCall` `ClaimedOnce` `ToolResultIffFinished` `NoOpenRowAfterDone`; `ToolTasksFinish` `RowsClose` | 339 | 2s |
| `Durable-stop.cfg` | F3 rewritten: 1 machine call, 1 Stop | `OneResultPerCall` `ToolResultIffFinished` `NoOpenRowAfterDone` `AbortEndsAborted`; `RowsClose` `AbortCompletes` | 470 | 3s |
| `Durable-crash.cfg` | F3 rewritten: 1 machine call, 1 step crash or raise | `OneResultPerCall` `ToolResultIffFinished` `NoOpenRowAfterDone`; `RowsClose` `ToolTasksFinish` | 361 | 3s |
| `Durable-stranded.cfg` | F4: 2 user inputs, model errors | `QueuedNotStranded` | 161 | 2s |
| `Durable-stop-stranded.cfg` | F4, Stop variant: 1 machine call, a routine, 1 Stop | `QueuedNotStranded` `PlacedSettles` | 7,357 | 5s |
| `Durable-withdraw.cfg` | F6: 1 machine call, a routine, 1 Stop | `BackgroundNotWithdrawn` `PlacedTracked` | 7,357 | 3s |
| `Durable-abortfail.cfg` | F7: 1 plain call, 1 Stop | `AbortEndsAborted` | 122 | 2s |
| `Durable-maxrounds.cfg` | F8: MaxRounds = 2 | `NoOrphanCalls` | 27 | 2s |
| `Durable-schedcrash.cfg` | F10: 2 user inputs, 1 Scheduler crash | `PlacedTracked` `AtMostOneActiveRun` `ToolResultIffFinished`; `PlacedSettles` | 378 | 2s |
| `Durable-schedule.cfg` | step 3: a routine firing twice into the conversation, 1 edit, 1 delete, no user input, 1 hub crash, 1 Scheduler crash, 1 step crash, 1 Stop | safety set and the schedule invariants | 7,283,126 | 5m17s (6 workers) |
| `Durable-schedule-retire-live.cfg` | step 3 review: a routine firing twice, retired with no replacement (a delete, or an edit that makes a repeating schedule a one-off at the slot it just fired), 1 hub crash | `RetiredEnds` `PlacedSettles` `NoRunningForever` | 394 | 2s (4 workers, 2026-10-06) |
| `Durable-schedule-thread.cfg` | step 3: the same, each firing starting a new thread, with 1 user input | safety set and the schedule invariants | 9,441,068 | 8m22s (4 workers) |
| `Durable-schedule-live.cfg` | step 3: a routine firing twice into the conversation, 1 edit, 1 user input, 1 hub crash, 1 Stop | `RetiredEnds` `PlacedSettles` `NoRunningForever` | 1,151,648 | 43m27s (4 workers; 2m44s of it the temporal check) |
| `Durable-bug-edit-keeps-old.cfg` | `Durable-schedule.cfg` with `BugEditKeepsOld` | fails `OneCarrier` (expected) | 2-state trace | 1s |
| `Durable-bug-fire-after-retire.cfg` | `Durable-schedule.cfg` with `BugFireIgnoresAbort` | fails `NoFireAfterRetire` (expected) | 8-state trace | 2s |

`Durable-schedule.cfg` has no user input, unlike the plan's first shape:
with one, TLC had covered 160M distinct states in two hours, the queue
still growing, when the run was stopped. The user's input adds nothing
the schedule properties read that the scheduled prompts don't already
do (they queue behind each other's runs, and the Stop finds them
queued), and `Durable-routine.cfg` covers a user's input beside a
routine. `Durable-schedule-thread.cfg` keeps its user input, since there
the conversation would otherwise be empty.

The state spaces are smaller than with node work (`Durable.cfg` had 6.1M
states, `Durable-parallel.cfg` 15.2M in 18 minutes): a machine call has no
watcher task, no report submission and no session, so
`Durable-parallel.cfg` now also has step crashes, model errors and an
offline machine, which it had to leave out before.

## Checks that the properties bite

Every config passes, so each machine-call property, and in step 3 each
schedule property that has no bug config of its own, was checked once
against a copy of the spec (or config) with one of the code's rules
broken. Each failed on the property meant to catch it:

| Rule broken | Config | Fails |
|---|---|---|
| `on_interrupt/2` doesn't cancel the op (hub rule 7) | `Durable-stop.cfg` | `NoOpenRowAfterDone`, 9 states: Stop while the call is parked |
| `Machines.start/1` inserts whatever the task's state (hub rule 9, HubOps H5) | `Durable-schedcrash-ok.cfg` | `NoOpenRowAfterDone`, 9 states: a Scheduler crash orphans the step, Stop aborts the task, then the orphan inserts the row |
| an error result or a rescued raise leaves the row alone (hub rule 10, HubOps H8) | `Durable-crash.cfg` | `NoOpenRowAfterDone`, 8 states |
| `cancel_tx/2` leaves a finished row as it is (HubOps H4) | `Durable-stop.cfg` | `RowsClose`, 11 states then stuttering: the op finishes between Stop and the abort commit |
| `claim_tx/2` doesn't close the row it claims (hub rule 8) | `Durable-double.cfg` | `OneResultPerCall`, 12 states |
| step 3: the fire step's commit isn't fenced on its start, only on the abort mark (F10 put back for routines) | `Durable-schedule-thread.cfg` without edits or deletes | `FireOncePerSlot`, 10 states: a Scheduler crash while the fire step runs, the routine starts again, and both steps commit their firing; with `Target = "thread"` that is two threads |
| step 3: an edit doesn't mark the old routine (`BugEditKeepsOld`) | `Durable-schedule-live.cfg` with no user input, hub crash or Stop, checking `RetiredEnds` only | `RetiredEnds`, 30 states then stuttering: the retired routine fires both times and ends `done` |

## What changed in build step 3

Step 3 moves Blip's routines into `Photon.Schedules`: a schedule is a
row, and its timer is a `"routine"` task that repeats, which the owner
can edit or delete from the project page at any time
(`docs/plans/step-3-skills-and-schedules.md`, sections 3.3 and 3.4). The
plan's claim is that the step fence alone (`Runtime.commit`, `Ignored`)
makes each firing happen once and never after its schedule was edited
or deleted. A new-thread firing (`Target = "thread"`) has no request ID
to dedupe on, so the fence is all there is. The spec was extended before
the code, as `HubOps.tla` was in step 1:

* Constants `Spares`, `MaxFires`, `MaxEdits`, `MaxDeletes`, `Target`,
  and the bug switches `BugEditKeepsOld` and `BugFireIgnoresAbort`.
  `Routines` now holds at most one routine, the schedule's first.
* Variables `carrier`, `fires`, `retired`, the ghosts `lateFire` and
  `dupFire`, the budgets `edits` and `deletes`, and the task field
  `fired` (the checkpoint's `"runs"`), which steps carry from their
  start.
* `RoutineFire` repeats: in one fenced commit it posts `RS(r, k)` or
  starts a thread, then waits again while `fired < MaxFires`, else
  finishes; a row that is gone finishes the task and writes nothing.
  `SubIds` has `RS(r, k)` for `k` in `1..MaxFires` (none with
  `Target = "thread"`).
* New actions `OwnerEdit` and `OwnerDelete`; new invariants
  `OneCarrier`, `NoFireAfterRetire` and `FireOncePerSlot`; new liveness
  property `RetiredEnds`. `BackgroundNotWithdrawn` now covers every
  `RS(r, k)`.
* Five configs: `Durable-schedule`, `-schedule-thread`, `-schedule-live`
  and the bug configs `-bug-edit-keeps-old` and `-bug-fire-after-retire`
  (see "Results" for why `Durable-schedule` has no user input).
  Every older config sets `Spares = {}`, `MaxFires = 1`, `MaxEdits = 0`,
  `MaxDeletes = 0`, `Target = "conv"` and both bug switches `FALSE`,
  which is the old model; all 15 reach exactly the state counts recorded
  before.

TLC found no problem in sections 3.3 and 3.4 of the plan, so they stand
as written.

The modeled conversation is Blip's: its Stop keeps scheduled prompts. A
thread's Stop withdraws them too (plan section 3.7), which is the
existing withdraw of a queued submission, so `BackgroundNotWithdrawn` is
about Blip. Times are left out (see "Abstractions"): `Rules.arm/4` and
`fired_through/3`, which decide the time an edited schedule waits for so
that an edit made in the second a schedule is due neither skips nor
repeats that firing, are pure and tested in
`test/core/schedules/rules_test.exs`.

### The bug configs

| Config | Defect put back | Fails |
|---|---|---|
| `Durable-bug-edit-keeps-old.cfg` | `Schedules.update/3` arms the new routine without marking the old one for abort | `OneCarrier`, 2 states: the edit itself leaves `r1` pending beside its replacement `r2`. Without `OneCarrier` in the config, `NoFireAfterRetire` fails in 8 states: the old routine goes on to fire |
| `Durable-bug-fire-after-retire.cfg` | the fire step's commit is fenced only on its start (`updated_at`), not on the abort mark | `NoFireAfterRetire`, 8 states (`-workers 1`): `r1` wakes and its fire step starts, the owner edits the schedule, then the step's commit posts `rs_r1_1` for the retired routine. The delete variant (the step finds the row gone) is as short, and also breaks `AbortEndsAborted`: the task marked for abort finishes `done` |

## What changed in build step 1

The node-work actions are gone with the code they modeled: `NodeRun`,
`NodeCreateWatcher`, `NodeWait` and `NodeResume` (`run_on_node` and
`NodeWork`), `WatchStart` and `WatchReport` (`NodeWatch`), and
`NodeSettle` (`NodeSessions.ingest/4`). So are the watcher tasks, the
report submissions, the node-session variables (`session`, `inputDone`,
`answerInTool`), the watcher's retry in `FailCommit`, and the properties
about delivering a node's answer once (`NoDoubleDelivery`,
`ReportsNotWithdrawn`, `DeliveredOnceAnswered` and its weaker forms). The
machine call (`MStart`, `MPark`, `MResume`, `MRepark`, `MClaim`, the row,
its cancel flag and its signal, `OpFinish`) and its properties
(`OneResultPerCall`, `ClaimedOnce`, `NoOpenRowAfterDone`, `RowsClose`)
take their place, and `BackgroundNotWithdrawn` replaces
`ReportsNotWithdrawn` for the input a Stop must keep, now a routine's
prompt. The constants `NodeOffline` and `ToolTypes`' `"node"` became
`MachineOffline` and `"machine"`, and `MaxRechecks` is new.

Configs: the watcher configs went (`Durable-crash-watcher`,
`-stop-watcher`, `-delivery`, `-delivery-ok`, `-fixresume`, `-fixes`),
since the faults they checked no longer exist: there is no watcher, and the
result and its signal were always one commit for ops (hub rule 4). The
configs whose fault still exists were rewritten for machine calls
(`-double`, `-stop`, `-crash`) or for routines (`-stop-stranded`,
`-withdraw`), and `-offline` is new. `-stranded`, `-abortfail`,
`-maxrounds` and `-schedcrash` have no tool that changed, and they reach
exactly the state counts recorded before.

## The findings, and how they were fixed

Traces are from the first version of the spec (the code before the fixes),
when the tools were node work; state numbers refer to its TLC traces. F1,
F2, F3, F5, F6 and F9 were about node work, which build step 1 deleted.
The rules their fixes introduced are still in the harness, and the
machine call relies on them: `{:commit, fun}` tool results (F1), the tool's
`on_interrupt/2` (F3), and Stop keeping background input (F6).

### F1. The same node answer could reach the user twice

Retired with node work. `Durable-double.cfg`, `NoDoubleDelivery`, 24
states, no faults. The tool's resume and the watcher's report both woke on
the same signal, and both delivered the answer.

Fixed: `NodeWork.resume/2` returned `{:commit, fun}` (a new tool result
form), which `ToolTask` runs inside the commit that records the result.
Machine calls claim their op's result the same way (`claim_tx/2`), and
`Durable-double.cfg` now checks `OneResultPerCall` and `ClaimedOnce` for
them.

### F2. A Stop (or a crash) during resume lost the answer

Retired with node work. `Durable-stop-watcher.cfg`, 21 states. Fixed by
F1's fix: an ignored commit (the call was aborted) rolled back the watcher
abort with it.

### F3. A Stop (or a crash) between starting the session and creating the watcher lost the answer

Retired with node work. `Durable-stop.cfg`, 12 states; step-crash variant
`Durable-crash.cfg`, 15 states.

Fixed: `Tool` got an optional `on_interrupt/2` callback that
`ToolTask.on_abort`/`on_fail` call in the commit that ends the call. A
machine call implements it with `cancel_tx/2`, and since step 1 a rescued
raise runs it too (hub rule 10). `Durable-stop.cfg` and `Durable-crash.cfg`
now check that every way a machine call ends cancels or closes its row.

### F4. Input queued behind a run that ended without answering was stranded

`Durable-stranded.cfg`, 6 states; Stop variant `Durable-stop-stranded.cfg`,
19 states (with a node report; a routine's prompt now). Only a run that
answered took the next input from the inbox.

Fixed: a run whose model request fails, or that hits the round limit,
settles its input `unanswered` and continues with the inbox like an
answered run (`Generation.continue_with_inbox/3`). When the Scheduler fails
or aborts a run, `Durable.continue_inbox/2` places the next input (all
queued steers, else the oldest follow-up) in a new run, which also covers
input sent while a stopped run was still being aborted.

### F5. A hub crash between ingest and signal lost the signal for good

Retired with node sessions. `Durable-delivery.cfg`, 23 states. Fixed then:
`NodeSessions.ingest/4` and `reject_input/3` ran as one Store commit with
`Tx.signal/3` inside. An op's terminal snapshot has always been recorded
with its signal in one commit (`Machines.snapshot/3`, hub rule 4), which
`OpFinish` models.

### F6. Stop withdrew background input

`Durable-withdraw.cfg`, 14 states. `Durable.abort` withdrew every queued
submission, node reports and routine prompts included, so whether they
survived a Stop depended on timing.

Fixed: `Durable.abort/2` takes a `:withdraw` filter, and `Assistant.stop`
withdraws only the user's own input. Routine prompts stay queued and start
the next run once the stopped run is aborted (F4's fix).
`Durable-withdraw.cfg` now checks `BackgroundNotWithdrawn` with a routine.

### F7. A Stop could end a task as "failed" instead of "aborted"

`Durable-abortfail.cfg`, 6 states. A step whose commit was ignored (Stop)
returned with its task still `running`; if the Scheduler handled that
before its reconcile pass, it called `fail/2` ("the step for phase request
ended without a transition").

Fixed: `Scheduler.fail/2` leaves a task marked for abort alone;
`stop_aborted` ends it as aborted.

### F8. Tool calls past `@max_rounds` never got a result

`Durable-maxrounds.cfg`, 12 states. The assistant entry with the calls was
stored, and no tool task or result was made.

Fixed: the round-limit branch appends a `tool_result` per call ("Not run:
the assistant stopped after 60 tool rounds.") in the same commit.

### F9. A crashed watcher lost the report

Retired with node work. `Durable-crash-watcher.cfg`, 23 states. Fixed
then: a kind's `on_fail/3` may return `:retry` (run the phase again), and
`NodeWatch` retried up to three runs. The retry is still in the Scheduler,
unused.

### F10. A Scheduler-only crash ran steps twice

`Durable-schedcrash.cfg`, 8 states. `init` reset running tasks to pending
and started them again while the old steps kept running, and
`Tx.transition` accepted both commits.

Fixed: step commits are fenced. `Runtime.commit` passes the task as the
step got it, and `Tx.transition/4` applies the transition only while the
task is still `running` with the same `updated_at`.

### F10b. Fencing on `runs` alone wasn't enough

The first version of the F10 fix compared `runs`. Model-checking it
(`Durable-schedcrash-ok.cfg` with `PlacedTracked`) found a 29-state trace:
`runs` restarts with each phase, so a step left over from one `after_tools`
start could match the `runs` of a later `request` start and commit into it.
The fence now uses `updated_at`, which every start changes; the model's
`tok` stands for it. ExUnit: "a leftover step can't commit into a later run
of its phase".

### Seen while reading, not modeled

* A step whose module isn't loaded yet: the Scheduler looked up `on_abort`
  and `on_fail` with `function_exported?/3`, which is false for an unloaded
  module (found by the property tests; fixed with `Code.ensure_loaded?/1`).
