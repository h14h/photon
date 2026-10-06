# Verification

This records how Photon's harnesses were checked, what was found, and what
was fixed. There are three parts:

- **TLA+ specs** in `specs/tla`, checked with TLC: `NodeSync` (hub and node
  session replication and the input outbox), `Durable` (the hub's durable
  harness and the assistant's node work), `Coordinator` (one node
  session's coordinator, its shell operations and the commands they run)
  and `HubOps` (build step 1's operation protocol: Blip's machine tools on
  the hub, their op rows, and the node's executor and journal).
- **Property tests** (StreamData) in each app's `test/property`.
- **Regression tests**: one or more deterministic ExUnit tests per bug,
  each written to fail on the code before the fix.

The verification pass found 43 issues: 8 in `NodeSync`, 10 in `Durable`, 12
in `Coordinator` (11 bugs and a known upstream gap) and 13 from the property
tests. Some are the same bug seen from two sides (the table at the end
groups them). Every one is fixed. Modeling one of the fixes found a flaw in
it (F10b), which is fixed too. None of the findings turned out to be a
modeling artifact; three test and modeling problems found while fixing
them are listed under "Artifacts".

A review of the fixes found two more bugs, both on the node, and fixed
them. The hub's stop could still be lost with a coordinator's mailbox
(NS-9: the bug NS-3 fixed for inputs, left in place for stops);
`NodeSync.tla` gained the property that catches it. And `Ops.add/2` could
hand the coordinator an operation process that had just exited, so an
operation whose command never ran was failed (node-op-stale-registry,
below the level of the specs). See the node table.

Nothing changed in the hub-node wire protocol, the node session log format
or the hub database schema; see "Compatibility".

Build step 1 (`docs/plans/step-1-machine-tools.md`) added the operation
protocol, and `HubOps.tla` was written for it before the code. TLC found
eight problems in the plan's first version of the protocol (H1 to H8),
and the plan was fixed before any code was written; four more bug
configs show the properties catch rules the plan already had. Once the
code was built, it was compared with the spec action by action, and no
modeled rule had changed. See "`HubOps.tla`" below and the step 1 table
under "Findings, triage and fixes".

## What each part covers

### `NodeSync.tla`

One node session, end to end: the node's log, `PhotonNode.Connection`
(replay after a join, live notifications, input delivery), the session
coordinator at the level of inputs, runs and stops, the websocket in both
directions, and the hub's mirror (`Photon.NodeSessions`: offsets, the input
outbox, settling and signals, `NodeChannel`). Faults: websocket drops,
hub restarts, node restarts, coordinator crashes, the idle-stop race,
refused deliveries, repeated sends, stops.

Properties: the hub's copy is a prefix of the node log and converges to it;
each input is logged at most once, gets into the log (or is refused), is
settled, and has its signal; a settled input always has its signal; no
input gets an answer from before it; a refused input never runs; a hard
stop holds until `stopped`, and no input is folded into it; a stop the
node takes while the session is working gets into the log.

Details, the action-to-code map and per-config results: `specs/tla/NodeSync.md`.

### `Durable.tla`

`Photon.Durable` (Store, Tx, Runtime, Scheduler, Generation, ToolTask) and
the assistant's node-work tools (`run_on_node`, `message_node_session`,
`NodeWatch`, `Routine`), with hub crashes, Scheduler-only crashes, step
crashes, user Stops, failing model requests, and the node's answer arriving
at any time.

Properties: one active run per conversation; one `tool_result` per tool
task and per stored call; bottom-up abort, and a stopped task ends
aborted; unsafe tools run at most once; placed input belongs to a live run
and settles; queued input leaves the inbox; nothing stays running; a node's
answer reaches the conversation exactly once, and reports are never
withdrawn.

Details: `specs/tla/Durable.md`.

### `Coordinator.tla`

One session's coordinator as pure state transitions with ordered side
effects, so a crash can happen after any prefix of a handler's log appends
and process starts. Since the node refactor the code has the same shape:
`PhotonNode.Harness.Session` is the pure state machine and `Coordinator`
runs its effects. Includes the hub outbox and websocket, the session log,
the model request task, shell operation processes and the OS commands
(process groups, background children, the `exit` and `pid` files).
Faults: coordinator crashes inside any handler, abrupt node crashes,
operation process crashes, websocket drops, duplicate deliveries, a tool
that goes away, commands that never exit.

Properties: replaying the log reproduces the live state; one model request
at a time; one result per call; a command starts at most once; the
Context stays well-formed; heartbeat arming; stops hold, complete, and
don't swallow input; `idle` is only written when nothing (logical or
physical) is left; every input is answered, every call gets a result, every
`running` settles.

Details: `specs/tla/Coordinator.md`.

### `HubOps.tla`

Build step 1's operation protocol, end to end, for one machine and one or
two `shell` calls: the call as a durable tool task
(`Photon.MachineTools.Call` under `Durable.ToolTask`), its op row and
signal (`Photon.Machines`, `Machines.Rules`), the Store's one line of
commits, the machine's `NodeChannel` and its mailbox, the websocket in
both directions, the node's `Connection`, and the node's executor with its
journal, operation processes and the OS commands. Faults: websocket drops,
hub restarts, Scheduler-only crashes (orphaned steps), node restarts that
keep or kill running commands, the node losing its data directory, user
Stops at any point, tool steps that end in an error, and repeated
`op.start` pushes.

Properties: a command runs at most once per call (and, after data loss,
an op the hub had confirmed never runs again); each call gets exactly one
result, and it is what its own op did; the offline message says "didn't
run" only when the command never ran; no `op.start` for a canceled row,
and the node never starts an op it was told to cancel; the node forgets an
op only after the hub recorded its result; a finished call leaves no row
that may still start; every call is answered, a cancel takes effect,
results are dropped on the node, and every row closes.

Unlike the other specs, its `-bug-*` configs are expected to fail. Each
puts back one defect with a switch in `Bugs` and shows the property that
catches it. Step 1 adds the `op.*` messages next to the session protocol
on the same channel; a node that doesn't list `"ops:1"` in its
capabilities is reported as outdated and gets no operations.

Details, the action-to-code map, per-config results and how the built
code compares with the spec: `specs/tla/HubOps.md`.

### Property tests

| App | File | What it checks |
| --- | --- | --- |
| core | `sse_property_test.exs` | `SSE.parse` gives the same payloads however a stream is cut (well-formed and arbitrary streams, bare CRs included) and never raises |
| core | `chat_completions_property_test.exs` | `decode_messages` inverts `encode_messages` (tool images go back into their results); the wire form survives JSON; streamed answers fold into the same message and events however the bytes are split; the hub's mock renderer round-trips; arbitrary chunks and message lists never raise (all on the pure `ChatCompletions.Request` and `ChatCompletions.Response`, no HTTP) |
| core | `llm_stream_property_test.exs` | an answer streamed over HTTP in any chunks gives `LLM.stream/3` the same result and events as the pure fold of the whole body |
| core | `message_property_test.exs` | `Message.arguments` never raises and decodes objects exactly; text/parts agree; `MockAgent` answers the same directly and through the hub's proxy |
| node | `context_property_test.exs` | `Context.build` pairs every tool call with one result, also when providers reuse call IDs; every input and finished result appears once, in order |
| node | `inbox_property_test.exs` | first valid input wins, repeats are dropped, the seen set is seeded from the log; validation never raises; only settings carry parameters; accepted content can always be encoded |
| core | `output_property_test.exs` | `Output.bound` gives valid UTF-8 and the documented head/tail/marker shape (moved from the node in step 1, with `PhotonCore.Output`) |
| node | `journal_property_test.exs` | step 1: an operation's journal entry survives a crash at any point of a write (torn temporary files, a crash between sync and rename): `read/2` returns the last entry fully written, or none, and the next write lands |
| node | `store_property_test.exs` | a log torn at any byte reopens to its complete records; `read` never raises on a torn tail |
| node | `session_property_test.exs` | random sessions on the pure session core (no processes or files), with coordinator restarts between handlers: replaying the log reproduces the session; effects keep the server's view (request, timers) in step; a request starts after its turn is persisted and only one runs; operations start after their status is persisted; a final status shows only snapshots persisted before it; a hard stop holds and no input is folded into it; the context stays well formed. Once settled, every input is logged once and answered, and every call has one final status |
| node | `coordinator_replay_property_test.exs` | random sessions on the real harness and mock model, with coordinator kills at random log positions, resends and stops: the log is well formed, each input logged once and answered, each command run at most once, and a restart from the final log writes nothing and reproduces the live state; a hard stop holds across a crash while stopping |
| hub | `node_sessions_property_test.exs` | `ingest` under duplicated, reordered and dropped deliveries keeps the hub's copy a prefix that converges after a resync; outbox states and signals match a model; arbitrary records never raise |
| hub | `durable_context_property_test.exs` | `Context.messages` pairs calls and results, sees nothing before the newest reset |
| hub | `durable_schema_property_test.exs` | `Schema.validate` never raises on the real tool schemas or on JSON Schema beyond its subset, and agrees with an independent reading of the subset |
| hub | `machine_ops_property_test.exs` | step 1: op rows under duplicated, stale and foreign snapshots, unknown ops, reconnects, cancels and claims, against `Photon.Machines` and the database: a row only moves forward, so an op finishes at most once; its signal fires exactly when it leaves `open`; `op.ack` only for finished or closed rows (or none); no `op.start` for a canceled row; a result is claimed at most once |
| hub | `durable_model_property_test.exs` | model-based test of the harness (submit, steer, follow-up, retried request IDs, the `go` signal, abort, full and scheduler-only restarts): one active run; retried requests submit once; once quiet, every submission settled and every call has one result; the transcript stays well formed across scheduler restarts; an abort before the task module is loaded still settles |

All of them run by default now. Properties tagged `:known_bug` (none at the
moment) are excluded from the default run.

The node's tests have been laid out by layer since the node refactor:
`test/core` (pure modules, the session core included), `test/boundary`
(the harness API, the coordinator, operation processes and the hub
connection, on a node in a temporary directory) and `test/property`. The
regression tests in the tables below kept their names and file names.

The hub's tests have been laid out the same way since the hub refactor:
`test/core` (the pure modules: `Durable.Policy`, `Turn`, `ToolCall`,
`Inbox`, `Context`, `Schema`, `NodeSessions.Mirror`, the assistant's
`Report`, `Prompt`, `Memory` and `Transcript`, and others, with no
database or processes), `test/boundary` (`Photon.Durable`,
`Photon.NodeSessions`, `Photon.Assistant` and provisioning through their
APIs, against the database and the harness's processes), `test/web` (the
node channel, LiveViews, controllers and plugs) and `test/property`. The
hub regression tests below kept their names and file names
(`test/boundary/node_sessions_test.exs`, `node_work_test.exs`,
`durable_regression_test.exs`; `test/web/channels/node_channel_test.exs`;
`test/core/durable/schema_test.exs`), some inside `describe` blocks now.
The rules several of them pin are also tested on the pure modules: F1 on
`NodeWork.resume_result/3`, F8 on `Turn.round_limit/0` and `Turn.not_run/1`,
and the malformed-record hardening on `NodeSessions.Mirror.effect/1`.

## How to run

ExUnit, in each app (the toolchain wrapper pins Elixir 1.20.4 / OTP 28):

```sh
cd apps/core && ~/.local/bin/mx mix test
cd apps/node && ~/.local/bin/mx mix test
cd apps/hub && ~/.local/bin/mx mix test
```

`mix test test/property` runs only the properties. `PHOTON_PROPERTY_RUNS=250`
raises the run count of the run-heavy model properties (node coordinator
replay, node session core, hub durable model, hub ingest). `mix test --include known_bug`
would also run properties pinning open bugs.

TLC (TLA+ tools 2.19 at `~/.local/share/tla/tla2tools.jar`), from
`specs/tla`:

```sh
java -XX:+UseParallelGC -cp ~/.local/share/tla/tla2tools.jar tlc2.TLC \
  -workers auto -deadlock -metadir /tmp/tlc/<Cfg> -config <Cfg>.cfg <Spec>.tla
```

where `<Spec>` is `NodeSync`, `Durable`, `Coordinator` or `HubOps` and
`<Cfg>` is one of its `.cfg` files. Add `-lncheck final` for configs with
`PROPERTIES`, and `-continue` for `Coordinator-witness.cfg`. `-deadlock`
is needed because every modeled behavior ends (the `HubOps` configs also
turn deadlock checking off themselves). The `HubOps-bug-*` configs are
meant to fail; `specs/tla/HubOps.md` lists the property each one breaks.

To run every config of every spec:

```sh
cd specs/tla
for cfg in *.cfg; do
  spec=${cfg%%-*}; spec=${spec%.cfg}; case $cfg in NodeSync*) spec=NodeSync;; esac
  extra=""; grep -q '^PROPERTIES' $cfg && extra="-lncheck final"
  [ $cfg = Coordinator-witness.cfg ] && extra="-continue"
  java -XX:+UseParallelGC -cp ~/.local/share/tla/tla2tools.jar tlc2.TLC -workers 4 \
    -deadlock $extra -metadir /tmp/tlc/${cfg%.cfg} -config $cfg $spec.tla | tail -3
done
```

## Results

ExUnit, final run (after the review): core 34 passed (15 properties, 19
tests), node 49 passed (15 properties, 34 tests), hub 80 passed (13
properties, 67 tests). The first pass ran each suite four times in a row
with no failure; the review ran each again (node twice with its final
code, plus its recovery tests three more times). The node and hub
property suites also pass with `PHOTON_PROPERTY_RUNS=150` and, in the
review, 300. All three apps pass
`mix format --check-formatted` and `mix compile --warnings-as-errors`
(dev and test).

Fail-first check: the new regression tests were run against a copy of the
apps with the original `lib/` restored. 45 of the 49 new tests failed there
for the reason they target (core 10 of 12, node 16 of 17, hub 19 of 20).
The 4 that passed are sanity tests that pin behavior the fixes must keep:
"arguments still decodes JSON text", "a user message that only looks like
tool images stays a user message", "a replay pushes what the hub is
missing and nothing it has", and "an answer the watcher hasn't reported
comes back in the result, and the watcher stops". The review's five new
node tests were checked the same way, against the code before the
review's fixes: four fail for the reason they target; the fifth ("a stop
for a session that isn't working starts nothing") pins behavior the fix
keeps.

TLC: all 56 configs were re-run in the review, and every one finishes
with no error except `Coordinator-witness.cfg`, which is
meant to violate its six witness invariants and does (it runs with
`-continue`; it hits all six thousands of times, and TLC 2.19 then throws
an internal `ArrayIndexOutOfBoundsException` while printing traces, a
tooling problem). State counts and times per config are in the spec
notes; the largest are `Durable-parallel.cfg` (15.2M distinct states,
14m46s), `Durable-routine.cfg` (6.7M, 4m57s), `Durable.cfg` (6.1M, 3m46s),
`Coordinator-faults.cfg` (2.0M, 6m00s), `Coordinator.cfg` (211K, 7m39s) and
`NodeSyncFixedNet.cfg` (255K, 4m12s). Times are on a shared 12-core machine
at load around 38, with 3 or 4 workers.

### Final review (2026-10-04)

After the verification pass and the three refactors, everything was run
again: in each app `mix precommit` (compile with warnings as errors,
unused-lock check, format, `credo --strict`, tests with warnings as
errors) and `mix dialyzer`; the node also compiles in `prod`, as
packaging does. Core 159 passed (16 properties, 143 tests, the custom
Credo checks' tests included), node 125 (16 properties, 109 tests), hub
289 (13 properties, 276 tests). The node and hub suites passed three runs
in a row, and the property suites again with `PHOTON_PROPERTY_RUNS=200`.
The pre-workflow test suites (core 7, node 12, hub 47 tests) were also run
against the new code: all pass except one hub channel test, which calls
`NodeSessions.start/3` without the durable Store running; node-session
writes go through the Store since the hub refactor (H3), so that is the
intended change. All 56 TLC configs were re-run: the 55 that should pass
do, each with the distinct-state count recorded in the spec notes, and
`Coordinator-witness.cfg` violates its six witness invariants, as it
should. One bug was found and fixed with tests (core-negative-retry-after
in the core table); the spec notes' code map was brought up to date where
it still named code the refactors had moved.

### HubOps (step 1, 2026-10-05)

`HubOps.tla` has 19 configs. The 7 clean ones pass, the largest being
`HubOps-two.cfg` (two calls, 49.3M distinct states, 27m40s),
`HubOps-errors.cfg` (1.8M, 23m58s, with every liveness property) and
`HubOps.cfg` (10.2M, 5m08s). Each of the 12 bug configs fails on its
property within a few seconds, with a trace of 5 to 24 states. Times are
on the shared 12-core machine with 4 workers (2 for the bug configs).
Per-config counts and traces: `specs/tla/HubOps.md`.

They were run against the plan, before the code. When the code was done,
it was compared with the spec action by action; no rule the spec models
had changed, so the configs weren't run again. The differences in shape
(for example `resume/2` reading the row before its commit, or a request
reaching a channel before its `:joined`) are written up in `HubOps.md`
with why the spec still covers them.

## Findings, triage and fixes

"Test" names the regression tests (file: test name). Specs name the config
that reproduced the bug and now passes.

### Node: replication, delivery, coordinator

| ID | Bug | Fix | Test | Spec |
| --- | --- | --- | --- | --- |
| NS-1 | `Connection.replay/3` read the log twice when nothing was new; a record appended between the reads was neither replayed nor pushed when announced, so the hub stayed a record short (often the final `idle`) until the next reconnect | the watermark comes from the same read (`from + length(records)`); `Store.count/1` removed | `connection_test.exs`: "a record appended while the join replays is pushed when it is announced" | `NodeSyncReplayRace` |
| NS-2, Coordinator F7 | `resume_all` skipped a session whose input was logged before its `running` record, and the hub never resends an accepted input | `Harness.working?/1` is also true for an external input after the last response or stop | `recovery_test.exs`: "a session with logged input it never started on is resumed on boot" | `NodeSyncResume`, `Coordinator-bug-not-resumed` |
| NS-3, Coordinator F6 | inputs in a crashed coordinator's mailbox were lost until the next reconnect | `Harness.deliver/3` is a call answered once the input is persisted; if the coordinator dies first it retries with the successor | `recovery_test.exs`: "an input in the mailbox of a coordinator that crashes still reaches the log" | `NodeSyncMailbox`, `Coordinator-bug-crash-loses-input` |
| NS-4, Coordinator F5 | an input sent to a coordinator stopping on `:idle_stop` died with it | same synchronous delivery with retry | `recovery_test.exs`: "an input that reaches a coordinator as it stops for idleness still reaches the log" | `NodeSyncIdleStop`, `Coordinator-bug-idle-stop-loses-input` |
| NS-6 | a run whose last response had no text (or failed) reported the previous run's answer | an accepted external input clears `last_answer` and `last_failure` (in `apply_input/2`, so replay agrees) | `recovery_test.exs`: "a run that ends without text doesn't report an earlier run's answer" | `NodeSyncStaleAnswer` (now also `AnswerAfterInput`) |
| NS-8, Coordinator F2, node-stop-lost-on-crash | a hard stop logged without its `stopped` record was forgotten on restart; the work resumed | `apply_input/2` arms the stop and `stopped` clears it, so replay re-arms it | `recovery_test.exs`: "a hard stop recorded before a restart still ends the work"; property "a hard stop holds when the coordinator crashes while stopping" | `NodeSyncStop`, `Coordinator-bug-stop-forgotten` |
| Coordinator F1 | a crash in the handler that started a turn orphaned the model request; the restart started a second one | the request task is linked (`Task.Supervisor.async`) and dies with the coordinator | `recovery_test.exs`: "the model request dies with its coordinator" | `Coordinator-bug-orphan-llm` |
| Coordinator F3 | a shell command could start twice: it started before its `process` checkpoint was stored | the shell asks the coordinator to persist the checkpoint by a call (`Coordinator.checkpoint/2`) and starts only on `:ok` (`:cancel` during a stop; otherwise it stops and is started again from the log) | `shell_test.exs`: "a command doesn't start until its coordinator has stored the checkpoint" | `Coordinator-bug-double-exec` |
| Coordinator F4 | an input accepted while a hard stop was finishing was marked delivered by `stopped` and never answered | external input that arrives during a stop is held and persisted after `stopped`, then answered | `recovery_test.exs`: "an input that arrives while a stop is finishing is answered after it" | `Coordinator-bug-stop-swallows-input` |
| Coordinator F8 | a cancel that reached a shell before its PID was known didn't kill the command; the stop never finished | the `pid` handler kills the group if a cancel came first | `shell_test.exs`: "a cancel that arrives before the command's PID is known still kills it" | `Coordinator-bug-cancel-before-pid` |
| Coordinator F9 | a crashed operation process went unnoticed; its call never got a result and the session stayed `running` | the coordinator monitors operation processes; a `:DOWN` fails a live operation (a clean exit before starting is dispatched again, once) | `recovery_test.exs`: "an operation process that crashes fails its operation" | `Coordinator-bug-op-crash` |
| Coordinator F10 | a recorded call whose tool no longer resolved (skills removed, tool disallowed) never finished, and every reconcile logged its result again | such a call gets a generic result once its operations finish | `recovery_test.exs`: "a call whose tool is no longer available still gets one result" | `Coordinator-bug-tool-vanish` |
| Coordinator F11 | a shell reattached after a node restart waited for background children of a command that had exited | `poll_recovered/1` checks the exit file first, then kills the group | `shell_test.exs`: "a reattached command that exits leaving background children finishes" | `Coordinator-bug-bg-reattach` |
| NS-9 (review) | the hub's stop was still a plain message: lost if the coordinator crashed or stopped for idleness before handling it (its successor carried on with the work), and dropped if it came while no coordinator ran though the log said the session was working (just after a crash, or before `resume_all`) | `Harness.stop/1` goes through the same call as `deliver/3`, retried with the next coordinator, and starts a coordinator for a working session | `recovery_test.exs`: "a stop in the mailbox of a coordinator that crashes still stops the work", "a stop for a working session with no coordinator running still stops it", "a stop for a session that isn't working starts nothing" | `NodeSyncStopLost` (`StopTakesEffect`); `HubStop` and `Retried` in `Coordinator.tla` |
| node-op-stale-registry (review) | `Registry.lookup/2` still lists a process that has just exited, so `Ops.add/2` could resend to a dead operation process; the coordinator's monitor got `:noproc` and failed the operation ("the operation process exited: no process") though its command never ran. Happens when a coordinator crashes while a shell waits on its checkpoint call, and on the re-dispatch after a clean exit | `Ops.add/2` starts a new process if the listed one isn't alive; `op_down/3` treats `:noproc` like a clean exit (dispatched again, once) | `recovery_test.exs`: "an operation whose old process has just exited is started again, not failed", "an operation process already gone when monitored isn't taken for a crash" | - (no registry in the model) |
| K1 (known upstream gap) | a node crash after the `process` checkpoint but before the PGID one left the command running unwatched while the session went `idle` | the wrapper writes the command's PID to a `pid` file; recovery reads it when the snapshot has no PGID | `shell_test.exs`: "a command started just before a crash is found through its pid file" | `Coordinator-known-orphan-command` |
| node-inbox-heartbeat-parameters | a heartbeat control with parameters was accepted (spec 5.1 allows parameters only on settings) | rejected like a hard stop with parameters | `inbox_test.exs`: "a heartbeat with parameters is rejected, like a hard stop" | property |
| node-inbox-poison-content (hardening) | the inbox accepted any list as content; a malformed part made every later model request raise | content must be text or text and image parts | `inbox_test.exs`: "external content must be text or well-formed parts" | property |

### Hub: node sessions, durable harness, assistant

| ID | Bug | Fix | Test | Spec |
| --- | --- | --- | --- | --- |
| NS-5, Durable F5 (also H3) | `ingest/4` settled inputs in one transaction and fired their signal in a second commit; a hub restart in between lost the signal for good; `reject_input/3` had the same shape | both run as one `Durable.Store` commit with `Tx.signal/3` inside; broadcasts after the commit | `node_sessions_test.exs`: "an input is never settled without its signal" | `NodeSyncSignal`, `Durable-delivery` |
| NS-7 | an input the node refused could be pushed again (a tool rerun reuses the id; a send racing a join pushes twice), run, and stay `failed` on the hub | `send_input` pushes only a still-queued input; `NodeChannel` pushes an input once per connection | `node_sessions_test.exs`: "an input the node refused is not pushed again"; `node_channel_test.exs`: "an input is pushed to a connected node at most once" | `NodeSyncReject` |
| Durable F1 | the node's answer could come back in the tool result and again as the watcher's report | `NodeWork.resume/2` decides inside the result's commit (new `{:commit, fun}` tool result): answer only if no report was posted, stopping the watcher in that commit; the watcher waits while the call is live | `node_work_test.exs`: "an answer already reported by the watcher isn't repeated in the tool result", "an answer the watcher hasn't reported comes back in the result, and the watcher stops" | `Durable-double` |
| Durable F2 | a Stop between the watcher abort and the tool result lost the answer | same fix: an ignored commit rolls the watcher abort back | `node_work_test.exs`: "a stopped call leaves its watcher alone, so the answer is still reported" | `Durable-stop-watcher` |
| Durable F3 | a Stop or crash after the session started but before the watcher existed left the work unwatched | new optional `Tool.on_interrupt/2`, called by `ToolTask.on_abort`/`on_fail`; node tools create the watcher if their input exists | `node_work_test.exs`: "a call stopped after it started node work leaves a watcher" | `Durable-stop`, `Durable-crash` |
| Durable F4, hub-abort-strands-submission | input queued behind a run that failed, hit the round limit, crashed, or was stopped stayed queued forever | failing runs continue with the inbox; when the Scheduler fails or aborts a run, `Durable.continue_inbox/2` starts the next one | `durable_regression_test.exs`: "input queued behind a run whose model request fails still gets answered", "input sent while a stopped run is still being aborted starts the next run"; property "once the harness is quiet, every submission has settled" | `Durable-stranded`, `Durable-stop-stranded` |
| Durable F6 | Stop withdrew queued node reports and routine prompts | `Durable.abort/2` takes `:withdraw`; `Assistant.stop` withdraws only the user's input | `node_work_test.exs`: "Stop withdraws the user's queued messages but keeps node reports" | `Durable-withdraw` |
| Durable F7 | a stopped task whose step returned first ended `failed` with "ended without a transition" | `Scheduler.fail/2` leaves a task marked for abort to `stop_aborted` | `durable_regression_test.exs`: "a run stopped while its step is finishing ends aborted, not failed" | `Durable-abortfail` |
| Durable F8 | calls in the last assistant entry of a run that hit the round limit got no result | one "Not run" `tool_result` per call in the same commit | `durable_regression_test.exs`: "a run that hits the round limit gives every stored call a result" | `Durable-maxrounds` |
| Durable F9 | a watcher whose step crashed failed for good | `on_fail/3` may return `:retry`; `NodeWatch` retries three runs, then reports what it knows | `node_work_test.exs`: "a watcher whose step keeps crashing still reports the answer" | `Durable-crash-watcher` |
| Durable F10, hub-scheduler-restart-duplicates-steps (also H2) | a Scheduler-only restart left old steps running and restarted their tasks; both committed (duplicate turns and tool runs) | step commits are fenced: `Tx.transition/4` applies only while the task is `running` with the `updated_at` the step started with | `durable_regression_test.exs`: "a step left over from a scheduler restart can't commit"; property "the stored transcript keeps each call's results within its round across scheduler restarts" | `Durable-schedcrash` |
| Durable F10b (found while modeling the F10 fix) | the first fence compared `runs`, which restarts with each phase, so a leftover step could commit into a later start of its phase | fence on `updated_at` instead | `durable_regression_test.exs`: "a leftover step can't commit into a later run of its phase" | `Durable-schedcrash-ok` (`PlacedTracked`) |
| hub-function-exported-unloaded | `on_abort`/`on_fail`/`replay` were looked up with `function_exported?/3`, false for an unloaded module, so an early abort skipped `on_abort` and left input `placed` | `Code.ensure_loaded?/1` first | `durable_regression_test.exs`: "a run aborted before its task module is loaded still settles its input"; the property of the same name | - |
| hub-schema-raises-beyond-subset (hardening) | boolean subschemas and enums of objects crashed validation; type lists accepted anything | boolean subschemas, type lists and non-text enums handled | `durable/schema_test.exs`: "boolean subschemas allow anything or nothing", "an enum of objects reports a mismatch instead of raising", "a list of types accepts any of them and rejects the rest" | property |
| hub-ingest-raises-on-malformed-record (hardening) | a record with a nil or non-text input id, or a non-text answer, crashed the ingest (and the channel, on every replay) | such fields are ignored; a non-object record is stored wrapped | `node_sessions_test.exs`: "records the hub can't use are stored without crashing the ingest" | property |

### Step 1: the operation protocol

`HubOps.tla` found H1 to H8 in the plan's first version of the protocol;
each was fixed in the plan before the code was written, so the code never
had them. The tests pin each fix in the code. H2 is a property of how the
code is built (the channel's reads are `Durable.commit/1` calls, so they
wait for a commit in progress), and no test can force the interleaving.
Test files are under `apps/hub/test` unless they name the node.

| ID | Problem | Fix (plan section 2.3) | Test | Spec |
| --- | --- | --- | --- | --- |
| H1 | an `op.start` built by `Machines.start/1` before the result was recorded, and pushed after the `op.ack`, ran a finished command again | hub rule 2: only the channel builds `op.start`, from the row as it is when it pushes (`Machines.push_for/2`); a `{:command, "op.start", _}` is dropped | `boundary/machines_test.exs`: "nothing once the row has finished: the stale-start trace"; `web/channels/node_channel_test.exs`: "an op.start built anywhere but the channel is dropped" | `HubOps-bug-stale-start` |
| H2 | a join that read the rows around the abort commit missed its `cancel`, and the command ran on | hub rule 2: the channel's reads go through `Durable.commit/1` and wait for a commit in progress | by construction (see above) | `HubOps-bug-unserialized-read` |
| H3 | a rolled-back Stop let a canceled op start, because the node answered "canceled before it started" without keeping it | node rule 7: that answer is journaled and kept until `op.ack` | node `boundary/executor_test.exs`: "a cancel before the start is journaled, so a later start runs nothing"; `integration/machine_tools_e2e_test.exs`: "an op stopped while the node was away is canceled before it starts when the node joins" | `HubOps-bug-cancel-unjournaled` |
| H4 | a finished row whose call was stopped kept its snapshot (up to 5 MB) for good | hub rule 7: `cancel_tx/2` closes a finished row and drops it; `abandon_tx/2` claims it | `boundary/machine_tools_test.exs`: "Stop after the result came in, before the call claimed it, closes the row without it"; `boundary/machines_test.exs`: "a result that came in first is closed and dropped", "an op that finished meanwhile is claimed instead" | `HubOps-bug-keep-finished` |
| H5 | a step orphaned by a Scheduler-only crash inserted its row after Stop, leaving an op nothing would cancel | hub rule 9: the insert happens only while the task is unfinished and not marked for abort | `boundary/machines_test.exs`: "inserts nothing for a task marked for abort, or finished"; `boundary/machine_tools_test.exs`: "a stopped task's op isn't recorded" | `HubOps-bug-unfenced-insert` |
| H6 | an offline give-up that raced a reconnect only set `cancel`, so the command the join had just started ran on | hub rule 7: `abandon_tx/2` sends `op.cancel` from inside its commit, like `cancel_tx/2` | `boundary/machine_tools_test.exs`: "the machine comes back between the offline check and the give-up: op.start went out, so the message hedges and the node gets op.cancel" | `HubOps-bug-abandon-silent` |
| H7 | the offline message said "the command didn't run" when the node had run it but no snapshot had arrived | hub rules 2 and 7: rows record `pushed`, and "didn't run" needs neither `pushed` nor `confirmed` | `core/machine_tools/wait_test.exs`: "says the command didn't run only when it was never pushed and never confirmed"; `boundary/machine_tools_test.exs`: the two offline tests | `HubOps-bug-offline-confirmed` |
| H8 | a call that ended in an error (a raise, or an error result after the row existed) left its row open for the next join to start | hub rule 10: every error result after the op ID cancels the op in its commit; a rescued raise runs `on_interrupt/2`; a rerun that finds the row parks | `boundary/machine_tools_test.exs`: "a raise after the op exists ends with an error, and cancels the op", "parks without checking the machine, even if it is now unknown"; `boundary/durable_test.exs`: "ends its call with an error, and its on_interrupt runs in the same commit" | `HubOps-bug-error-skips-cancel` |
| rules the plan had | an early `op.ack`, a spawn before the journal, an `op.start` after a cancel, no `known` flag | hub rules 4 and 7, node rules 3 and 4 | `boundary/machines_test.exs`: "a result is stored with its signal, then acked", "a join resends op.cancel for a canceled row, and never op.start"; node `boundary/executor_test.exs`: "an operation the hub has seen but the node has no record of fails without running", "a cancel journaled before the command's start means it never spawns"; node `boundary/shell_test.exs`: "a command doesn't start until its owner has stored the checkpoint" | `HubOps-bug-ack-early`, `-bug-spawn-before-journal`, `-bug-start-after-cancel`, `-bug-no-known` |

### Core: model client and message format

| ID | Bug | Fix | Test |
| --- | --- | --- | --- |
| core-sse-crlf-split | `SSE.parse` normalized CRLF in the buffer it returned and again on the next call, so a payload's trailing CR depended on where the stream was cut; bare CR wasn't a line end; every leading space was trimmed | WHATWG line endings (CRLF, LF, CR), a trailing CR held back, one space dropped, field name must be `data` | `core/sse_test.exs`: "a CR before a CRLF gives the same payload however the stream is cut", "the shrunk counterexample parses the same whole and cut at byte 8", "bare CR ends a line, and a CRLF split across chunks is one line ending", "only one space after the colon is dropped, and the field name must be data" |
| core-stream-raises-on-malformed-chunks | chunks of unexpected shapes raised inside the stream fold (`choices` not a list, `delta` a string, tool arguments sent as an object) | unexpected shapes are skipped; object arguments become JSON text; non-text finish reasons and usage are ignored | `core/chat_completions/response_test.exs` (the fold is pure now, so these feed it bytes without HTTP): "chunks of an unexpected shape are skipped instead of raising", "tool-call arguments sent as an object become JSON text", "an error chunk whose message isn't text still becomes an error" |
| core-mockagent-proxy-divergence | through the hub's mock proxy a tool image came back as a separate user message, which `MockAgent` took for a new prompt ("view from") | `decode_messages/1` puts the images back into their tool results, so it inverts `encode_messages/1` | `core/chat_completions/request_test.exs`: "the mock agent answers the same directly and through the hub's proxy", "a user message that only looks like tool images stays a user message" |
| core-decode-messages-raises (hardening) | content that wasn't text or a list raised | unknown shapes are skipped | `core/chat_completions/request_test.exs`: "decode_messages skips content and calls of an unexpected shape" |
| core-message-arguments-raises (hardening) | a call without `arguments`, or with non-text arguments, raised | missing means `{}`, an object is taken as is, anything else is an error | `core/message_test.exs`: "arguments never raises for a call without text arguments" |
| core-negative-retry-after (final review) | a negative `Retry-After` header became a negative `retry_after`, and `Process.sleep/1` raised on it, crashing the caller's request task (the node's model request, or the hub's generation step) instead of retrying | a negative value is ignored like any other malformed one, so the retry uses the usual backoff | `core/http_error_test.exs`: "ignores a negative retry-after, which no wait can honor"; `boundary/llm_test.exs`: "a provider that asks for a negative retry-after is retried with the usual backoff instead of crashing the caller" |

The five findings marked "hardening" were reported as not likely real bugs:
current callers can't produce those inputs. The properties are valid and
the fixes small, so they were fixed rather than dismissed.

## Artifacts

Problems in the tests and models found while fixing, as opposed to bugs in
the code:

- The property "decoding an encoded conversation keeps every message's
  meaning" encoded the old, lossy decode (tool images moved into a user
  message) as expected. With `decode_messages/1` now inverting
  `encode_messages/1`, the expected value keeps images with their results.
  A round that reuses a call ID is inherently ambiguous on the wire; the
  property spells out the rule the decoder uses.
- The hub test "hands work to a node and returns a quick answer" relied on
  the tool winning a race against the watcher. With F1 fixed, the losing
  case no longer doubled the answer but moved it into the report, so the
  test became flaky. The watcher now waits while the call that started the
  work is live, which makes the quick answer deterministic.
- `Coordinator-bug-cancel-before-pid.cfg` uses `SpecUnboundedCommands`
  (commands may run forever), where `RunningSettles` can't hold without a
  stop. It checks `StopCompletes` only.

The original verification notes also list four modeling artifacts in
`Coordinator.tla` and two in `NodeSync.tla` that were fixed before the
findings were reported; the spec notes keep them.

## Compatibility

- **Wire protocol**: unchanged. The node now handles a pushed `input` only
  once it is in the log; the hub pushes an input once per connection and
  only while it is queued. Both sides accept the old behavior.
- **Node session log**: unchanged (no new record kinds or fields). Replay
  of an older log whose hard stop never got its `stopped` record would
  re-arm the stop unless an `idle` record follows it. Shell operation
  directories gain a `pid` file.
- **Hub database**: no schema change and no migration. Signals for node
  inputs are now written in the same commit as the settle. New `node_watch`
  tasks carry `tool_task_id` in their input; older ones without it report
  as before.
- **Internal APIs**: `Harness.deliver/3` is synchronous, and so is
  `Harness.stop/1` (it returns once the stop is in the log, and starts a
  coordinator for a session whose log says it is working);
  `Coordinator.checkpoint/2` is new; `Ops.add/2` returns `{:ok, pid}`;
  `Store.count/1` is gone; `Durable.abort/2` takes `:withdraw`;
  `Tx.transition/4` takes the started task; tools may return
  `{:commit, fun}` and define `on_interrupt/2`; a task kind's `on_fail/3`
  may return `:retry`.

## Limits

- Power loss isn't modeled: a reader could see a record before `datasync`
  finished, and the record could then vanish.
- `Coordinator.tla` kills a shell waiting on its checkpoint call at the
  moment of the crash. The code's extra path (the new coordinator reaches
  the old process before it exits, and dispatches again on its clean exit)
  is covered by the ExUnit tests, not the model.
- `NodeSessions.ingest/4` now goes through the `Durable.Store` process, so
  node records and durable commits share one serialized writer. That is the
  design's intent (H3), but a very long replay now queues behind it. Since
  the hub refactor, `start/3`, `send_input/3` and `delete/1` commit through
  it too, so it is the only writer.
- Delivery is now a call, so while a session finishes a hard stop
  (commands get SIGTERM, then SIGKILL after five seconds) a new input for it
  waits, and the node's `Connection` waits with it. A call that times out
  (30 s) is treated as delivered, as before the fix; the input is still held
  by the coordinator and is persisted when the stop completes. If that
  coordinator then dies, the input is lost until the node reconnects (the
  hub pushes an input once per connection). Stops go through the same call.
- Stops go through the hub's input outbox (a hard-stop input), so one sent
  while the node is offline reaches it when it reconnects, in order with the
  messages around it; a node whose session isn't working by then refuses it.
  Deletes are still sent once and not stored: a node that is offline then
  keeps its copy of the session.
