# Durable: the hub's durable harness and the assistant's node work

`Durable.tla` models `Photon.Durable` (Store, Tx, Runtime, Scheduler,
Generation, ToolTask) and the assistant's node-work tools (`run_on_node` and
`message_node_session` through `Photon.Assistant.NodeWork`, `NodeWatch`,
`Routine`), with hub crashes, Scheduler crashes, step crashes, user Stops,
and the node's answer arriving at any time. It follows the code after the
verification fixes.

The first version modeled the code before the fixes, with four what-if
switches. It found ten bugs (F1 to F10 below), all now fixed in the code.
The switches are gone and the spec models the fixed code; each bug's config
is kept as a regression check (same constants, the same property, and in
several cases a stronger one). Modeling the first fix for F10 found a flaw
in it (F10b), which is fixed too. Every config is expected to finish with no
error. `docs/verification.md` lists the ExUnit regression test for each
finding.

Paths below are relative to `apps/hub/lib/photon/`.

## What is modeled

One conversation (every property is per conversation; other conversations
only share the commit line and the Scheduler, and the model already
interleaves those freely).

| Spec variable | Code |
|---|---|
| `task` | `tasks` table (`durable/task_record.ex`): status, phase, runs, abort_requested, owner, background, waiting (`on`/`signal`/`until`), checkpoint (`submissions`, `rounds`); `tok` stands for the `updated_at` a step's start wrote |
| `sub` | `submissions` table (`durable/submission.ex`): status, mode, insertion order |
| `signal` | `signals` table, one per node input (`node_input:<in>`) |
| `toolResults`, `answerInTool`, `orphanCalls` | the `tool_result` and `assistant` entries that matter for the properties |
| `session`, `inputDone` | `node_sessions` and `node_inputs` rows |
| `steps`, `inc` | step processes under `Durable.TaskSupervisor`, and which Scheduler incarnation started them |
| `untilPassed` | wall clock relative to each waiting task's `until` |

Ids are fixed so the state space stays small. Tool task `t1` has input
`in_t1`, watcher `wt1` (request id `watch:in_t1`) and report submission
`rep_t1` (request id `report:in_t1`). Generations `g1, g2, ...` are
allocated as `submit_tx` and `continue_inbox` create them.

### Actions and the code they follow

Every `Store.commit` is one atomic action. Work a step does outside a
commit (`NodeSessions.start`, which makes Store commits of its own, and
model calls) is its own action, so other commits can land in between.

Since the hub refactor, the decisions the actions model sit in pure
modules: the scheduler's in `durable/policy.ex` (`Policy`), a generation's
in `durable/turn.ex` (`Turn`), a tool call's in `durable/tool_call.ex`
(`ToolCall`), the inbox's in `durable/inbox.ex` (`Inbox`), and the node
mirror's in `node_sessions/mirror.ex` (`Mirror`). The table names both the
boundary function and the rule it applies.

| Action | Code |
|---|---|
| `UserSubmit` | `Durable.submit/submit_tx` with `Inbox.submit_action/3`: request-id dedupe, busy means queued, idle means placed plus a new generation |
| `UserAbort` | `Assistant.stop` -> `Durable.abort/2`: withdraw the user's queued input (node reports and routine prompts stay), `Tx.request_abort` the active run |
| `SchedStart` | `Scheduler.start_pending`/`start` (`Policy.start_action/4`, `startable?/1`, `start/1`): pending to running, `runs + 1`, a new `updated_at` (`tok`), spawn the step |
| `SchedWake` | `Scheduler.wake_waiting`, `wake?/2` and `fail_fast/2`, with `Policy.wakeable?/1`, `wake?/3` (and its `on_ready?/3`) and `fail_fast_aborts/2` |
| `SchedKill`, `SchedAbort` | `Scheduler.stop_aborted`: `terminate_child` for `Policy.steps_to_kill/2`, then abort bottom-up (`Policy.ready_to_abort/1`, `abort_tx/2` with `Policy.abort?/1`) with `on_abort`, then `Durable.continue_inbox/2` for a run |
| `SchedExit` | step result or `:DOWN`: a task still `running` and not marked for abort (`Policy.failable?/1`) fails through `fail/2` with `on_fail` (a watcher retries: `Policy.after_failure/1`), then `continue_inbox` for a run |
| `GenRequest` | `Generation.step("request")` with `answered/4` and `follow/5` on `Turn.outcome/2`: answer and continue with the inbox, tool calls, too many rounds (a `tool_result` per stored call, `Turn.not_run/1`, then the inbox), model error (then the inbox) |
| `GenAfterTools` | `Generation.step("after_tools")` (`Turn.after_tools/2`) |
| `NodeRun` | `RunOnNode.execute` up to `NodeSessions.start` (Store commits of its own) |
| `NodeCreateWatcher` | `NodeWork.await`'s `Durable.create_task`, its own commit |
| `NodeWait` | the `{:wait, signal + until}` transition |
| `NodeResume` | `NodeWork.resume/2` -> `{:commit, fun}`: one commit reads the signal and the report submission, stops the watcher and keeps the answer only if no report was posted (`NodeWork.resume_result/3`) |
| `PlainRun`, `ToolFinish` | a tool with the default `replay :unsafe` (a rerun after a crash reports "interrupted": `ToolCall.plan/3`); `ToolTask.finish` |
| `WatchStart`, `WatchReport` | `NodeWatch`: wait on the signal (`wait_for_signal/1`); then, while the call that started the work is live (`call_live?/1`), wait for it; else submit the report (`Report.node_report/2`) |
| `RoutineStart`, `RoutineFire` | `Routine` one-off (`first_wait/1`, `after_fire/2`) |
| `NodeSettle` | `NodeSessions.ingest/4` (and `reject_input/3`): settle the input and record the signal in one Store commit (`Mirror.effect/1`) |
| `Tick` | a waiting task's deadline passes |

`Runtime.commit` is "apply everything, or nothing if the task finished, was
marked for abort, or is not the start this step belongs to"
(`Tx.transition/4` with the started task; `Ignored(st)`). `Tx.finish`
aborts live foreground children. The tool hooks run in the commit that ends
the call: `ToolTask.on_abort`/`on_fail` call the tool's `on_interrupt/2`,
which for node tools creates the watcher if the session was started
(`OnAbortTk`).

### Faults

* `HubCrash`: the BEAM dies between any two actions. Steps vanish; the DB
  stays. On boot `Scheduler.init` puts running tasks back to pending.
* `SchedCrash`: only the Scheduler process dies and its supervisor
  (`Photon.Durable.Supervisor`, `:one_for_one`) restarts it. The step processes live under a separate `Task.Supervisor`
  started with `async_nolink`, so old steps keep running while `init`
  resets their tasks to pending; their commits are fenced out.
* `StepCrash`: a step process raises outside the tool's `rescue`, or exits,
  at any point before its last commit.
* `UserAbort`: Stop at any time.
* The node may answer any time after the session starts, or never.

Message loss, duplication or reordering between hub and node is not
modeled here (see `NodeSync.tla`).

### Abstractions and why they are sound

* The Scheduler's reconcile pass is split into per-task actions that can
  happen in any order, interleaved with step commits. Each of its commits
  re-reads the task, and the one stale input it keeps (the `blocked` set in
  `stop_aborted`) only shrinks for a task already marked for abort. The
  split allows every real order plus some extra ones, which can't hide a
  safety violation.
* A model request has no side effects before its commit, so the model's
  answer is chosen at commit time. `NodeWatch`'s reads (the payload, the
  call's status) are folded into its commit: if the call finishes between
  the read and the commit, the watcher waits on a finished task, wakes at
  once and reports, which the model covers.
* A step whose commit moved its task out of `running` is dropped right
  away; one that returns while its task is still `running` stays until
  `SchedExit` handles it.
* The fence: in the code, `Tx.transition/4` compares the task's
  `updated_at` with the one the step started with. While a step runs, only
  an abort request changes its task (and then the transition is ignored
  anyway), so `tok` (bumped at each start) captures exactly that.
* `NodeWatch.on_fail` retries up to three runs, then reports what it knows.
  Step crashes are bounded by `MaxStepCrashes`, so the model writes it as a
  retry and never reaches the give-up path.
* `message_node_session` is the same as `run_on_node` from the durable side.
  Recurring routines, `cancel_schedule`, `when_busy: "reject"`,
  `withdraw/1`, documents, entry ordering, PubSub and live events are left
  out. No task kind waits with `fail_fast`; `GenPolicy` lets the generation
  use it as a what-if.

### Fairness

The Scheduler reconciles after every commit that touches tasks or signals,
after every step result or `:DOWN`, and on its timer, so its actions are
weakly fair. Steps keep running, and time passes. The user, the node and
faults get no fairness. The crash budgets are finite.

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
| `NoDoubleDelivery` | a node input's answer is not both in the tool result and in a report the user sees |
| `ReportsNotWithdrawn` | a node report is never withdrawn |

Liveness:

| Name | Meaning |
|---|---|
| `PlacedSettles` | placed input eventually becomes `done` or `unanswered` |
| `QueuedNotStranded` | queued input eventually leaves the inbox |
| `ToolTasksFinish` | every tool task finishes |
| `NoRunningForever` | no task stays `running` forever (after crashes) |
| `AbortCompletes` | a task marked for abort finishes |
| `FinishedLeavesNoLiveWork` | a finished task's foreground children all finish |
| `DeliveredOnceAnswered` | once the node has answered an input, the user gets the answer (tool result or report in the transcript) |

`DeliveredUnlessWithdrawn`, `DeliveredOrReported`, `ReportedOrUnwatched`
and `DeliveredUnlessWithdrawnOrUnwatched` are weaker forms of the last one
that the first version used to get past one loss to the next. With the
fixes the strong form holds wherever it is checked.

## How to run

```sh
cd specs/tla
java -XX:+UseParallelGC -cp ~/.local/share/tla/tla2tools.jar tlc2.TLC -workers auto -deadlock \
  -metadir /tmp/tlc-Durable -config Durable.cfg Durable.tla
```

Swap `Durable.cfg` for any variant below, and add `-lncheck final` for
configs with `PROPERTIES`. `-deadlock` turns off deadlock checking: a
conversation that has answered everything is supposed to stop.

## Results

TLC 2.19, 3 workers on a shared 12-core machine at load around 38. Every
config: no error.

| Config | Shape | Checks | Distinct states | Time |
|---|---|---|---|---|
| `Durable.cfg` | 2 user inputs, 1 tool call (node or unsafe plain), 2 rounds, model errors, 1 hub crash, 1 step crash, 1 Stop | safety: AtMostOneActiveRun ToolResultIffFinished AbortedHasNoLiveFgChildren UnsafeAtMostOnce PlacedTracked NoOrphanCalls AbortEndsAborted NoDoubleDelivery ReportsNotWithdrawn | 6,087,848 | 5m05s |
| `Durable-parallel.cfg` | 1 user input, 2 tool calls in one response, 1 hub crash, 1 Stop | same safety set | 15,170,316 | 18m42s |
| `Durable-routine.cfg` | 1 user input, 1 node call, a routine firing at any time, node may be offline, model errors, 1 hub crash, 1 step crash, 1 Stop | same safety set | 6,664,046 | 6m14s |
| `Durable-live.cfg` | 1 user input, 1 tool call, model errors, 1 hub crash, 1 step crash, 1 Stop | PlacedSettles ToolTasksFinish NoRunningForever AbortCompletes FinishedLeavesNoLiveWork QueuedNotStranded DeliveredOnceAnswered | 138,298 | 5m03s |
| `Durable-schedcrash-ok.cfg` | 1 user input, 1 tool call, 1 Scheduler crash, 1 hub crash, 1 Stop, model errors | safety set incl. PlacedTracked, NoDoubleDelivery | 627,784 | 40s |
| `Durable-delivery-ok.cfg` | 2 user inputs, 1 node call, 1 hub crash | DeliveredOnceAnswered | 115,922 | 24s |
| `Durable-fixresume.cfg` | 1 node call, 1 hub crash, 1 Stop | NoDoubleDelivery ToolResultIffFinished AtMostOneActiveRun; ReportedOrUnwatched DeliveredOnceAnswered | 30,896 | 12s |
| `Durable-fixes.cfg` | 1 node call, model errors, 1 hub crash, 1 Stop | safety incl. PlacedTracked NoDoubleDelivery ReportsNotWithdrawn AbortEndsAborted; QueuedNotStranded PlacedSettles DeliveredUnlessWithdrawn DeliveredOnceAnswered | 33,952 | 29s |
| `Durable-double.cfg` | F1 regression: no faults | NoDoubleDelivery ToolResultIffFinished | 655 | 1s |
| `Durable-stop-watcher.cfg` | F2 regression: 1 Stop | ReportedOrUnwatched DeliveredOnceAnswered | 3,380 | 3s |
| `Durable-stop.cfg` | F3 regression: 1 Stop | DeliveredOnceAnswered | 3,380 | 3s |
| `Durable-crash.cfg` | F2/F3 regression: 1 step crash | DeliveredOnceAnswered | 2,677 | 3s |
| `Durable-stranded.cfg` | F4 regression: 2 user inputs, model errors | QueuedNotStranded | 161 | 1s |
| `Durable-stop-stranded.cfg` | F4 regression (Stop variant): 1 Stop | DeliveredUnlessWithdrawn QueuedNotStranded DeliveredOnceAnswered | 3,380 | 4s |
| `Durable-delivery.cfg` | F5 regression: 1 hub crash | DeliveredOnceAnswered | 6,158 | 3s |
| `Durable-withdraw.cfg` | F6 regression: 1 Stop | ReportsNotWithdrawn NoDoubleDelivery | 3,380 | 2s |
| `Durable-abortfail.cfg` | F7 regression: 1 Stop | AbortEndsAborted | 122 | 1s |
| `Durable-maxrounds.cfg` | F8 regression: MaxRounds = 2 | NoOrphanCalls | 27 | 1s |
| `Durable-crash-watcher.cfg` | F9 regression: 1 step crash | DeliveredOnceAnswered | 2,677 | 3s |
| `Durable-schedcrash.cfg` | F10 regression: 2 user inputs, 1 Scheduler crash | PlacedTracked AtMostOneActiveRun ToolResultIffFinished; PlacedSettles | 378 | 1s |

`Durable-parallel.cfg` is the one run over ten minutes. The state counts
are larger than in the first version: the start token (`tok`) tells apart
states that differ only in how many times a task has started, and the
configs check more properties.

After the hub refactor (2026-10-03), which moved the scheduler's rules and
the task kinds' decisions into pure modules and changed only comments here
(the code is now cited by function rather than by line), all 20 configs
were re-run with 4 workers: no error, and the same distinct-state counts
as in the table (`Durable-parallel.cfg` took 15m06s).

## The findings, and how they were fixed

Traces are from the first version of the spec (the code before the fixes);
state numbers refer to its TLC traces.

### F1. The same node answer could reach the user twice

`Durable-double.cfg`, `NoDoubleDelivery`, 24 states, no faults. The tool's
resume and the watcher's report both woke on the same signal. The watcher
committed its report first; the tool read the signal, called
`Durable.abort_task(watcher)` (a no-op on a finished task) and committed a
result with the answer. The model then relayed it twice.

Fixed: `NodeWork.resume/2` returns `{:commit, fun}` (a new tool result
form). `ToolTask` runs `fun` inside the commit that records the result: it
reads the signal and looks for the report submission (`report:<input>`);
with no report it stops the watcher and keeps the answer, otherwise it says
the report is in the conversation. The watcher also waits while the call
that started the work is live (`NodeWatch.step("report")`), so a quick
answer comes back as the call's result.

### F2. A Stop (or a crash) during resume lost the answer

`Durable-stop-watcher.cfg`, 21 states. The watcher abort was its own commit
before the result; a Stop in between aborted the call (result "Stopped by
the user"), and the watcher was already gone.

Fixed by F1's fix: an ignored commit (the call was aborted) rolls back the
watcher abort with it.

### F3. A Stop (or a crash) between starting the session and creating the watcher lost the answer

`Durable-stop.cfg`, 12 states; step-crash variant `Durable-crash.cfg`, 15
states. `NodeSessions.start` had pushed the input, and the step was killed
before `Durable.create_task(watcher)`.

Fixed: `Tool` gets an optional `on_interrupt/2` callback that
`ToolTask.on_abort`/`on_fail` call in the commit that ends the call. The
node tools implement it with `NodeWork.ensure_watcher/2`: if the call's
input exists (the work was handed to a node), create the watcher
(idempotent by request id).

### F4. Input queued behind a run that ended without answering was stranded

`Durable-stranded.cfg`, 6 states; Stop variant `Durable-stop-stranded.cfg`,
19 states. Only a run that answered took the next input from the inbox.

Fixed: a run whose model request fails, or that hits the round limit,
settles its input `unanswered` and continues with the inbox like an
answered run (`Generation.continue_with_inbox/3`). When the Scheduler fails
or aborts a run, `Durable.continue_inbox/2` places the next input (all
queued steers, else the oldest follow-up) in a new run, which also covers
input sent while a stopped run was still being aborted.

### F5. A hub crash between ingest and signal lost the signal for good

`Durable-delivery.cfg`, 23 states. Same bug as NS-5 in `NodeSync.md`.

Fixed: `NodeSessions.ingest/4` and `reject_input/3` run as one Store commit
with `Tx.signal/3` inside.

### F6. Stop withdrew node reports

`Durable-withdraw.cfg`, 14 states. `Durable.abort` withdrew every queued
submission, node reports and routine prompts included, so whether an answer
survived a Stop depended on timing.

Fixed: `Durable.abort/2` takes a `:withdraw` filter, and `Assistant.stop`
withdraws only the user's own input. Reports and scheduled prompts stay
queued and start the next run once the stopped run is aborted (F4's fix).

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

`Durable-crash-watcher.cfg`, 23 states. `NodeWatch` had no `on_fail`, and
nothing restarts a failed task.

Fixed: a kind's `on_fail/3` may return `:retry` (run the phase again);
`NodeWatch` retries up to three runs, then posts the answer if it has come
or a "lost track of it" report.

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

* `message_node_session` to a session that is still busy: when the session
  goes idle, every accepted input is settled with the same final answer.
  Each input then delivers that text once, so per-input exactly-once holds
  while the user still reads one answer twice.
* A step whose module isn't loaded yet: the Scheduler looked up `on_abort`
  and `on_fail` with `function_exported?/3`, which is false for an unloaded
  module (found by the property tests; fixed with `Code.ensure_loaded?/1`).
