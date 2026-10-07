# Verification

This records how Photon's harnesses were checked, what was found, and what
was fixed. There are three parts:

- **TLA+ specs** in `specs/tla`, checked with TLC: `Durable` (the hub's
  durable harness, its machine calls, schedules and `ask_blip`), `HubOps` (build step 1's
  operation protocol between the hub and a node) and `Executor` (the
  node's executor, its journal, the operation processes and the commands
  they run).
- **Property tests** (StreamData) in each app's `test/property`.
- **Regression tests**: one or more deterministic ExUnit tests per bug,
  each written to fail on the code before the fix.

The verification pass, before build step 1, found 43 issues: 8 in
`NodeSync` (a spec of node session replication), 10 in `Durable`, 12 in
`Coordinator` (a spec of one node session's coordinator: 11 bugs and a
known upstream gap) and 13 from the property tests. Some are the same bug
seen from two sides (the tables at the end group them). Every one was
fixed. Modeling one of the fixes found a flaw in it (F10b), which was
fixed too. A review of the fixes found two more bugs on the node (NS-9
and node-op-stale-registry), also fixed.

Build step 1 (`docs/plans/step-1-machine-tools.md`) replaced node sessions
with machine tools. `HubOps.tla` was written for the new protocol before
the code, and TLC found eight problems in the plan's first version of it
(H1 to H8), all fixed in the plan before any code was written. PR B then
deleted node sessions, the model relay and the node's agent loop, and the
specs with them:

- `NodeSync.tla` and its configs are gone. Session replication, the input
  outbox and node reports no longer exist.
- `Coordinator.tla` became `Executor.tla`. The session coordinator is
  gone; its operation processes now belong to the executor. The new spec
  keeps the operation-process part and adds executor crashes. Its bug
  configs put back F3, F8, F9, F11 and K1, and node rule 10's `stopped`
  marker, and fail as they should. It found two gaps in the code as first
  built (E1 and K2, see the step 1 table); both are fixed, and each now
  has a bug config that puts it back.
- `Durable.tla` lost node work (`run_on_node`, `NodeWork`, `NodeWatch`)
  and models a machine call in its place: its op row, its signal, the
  periodic recheck, the offline give-up, and Stop with the row's cancel
  flag.

The findings tables below keep every row. Rows whose code is gone are
marked retired: their fixes went with the code, and so did their
regression tests.

## What each part covers

### `Durable.tla`

`Photon.Durable` (Store, Tx, Runtime, Scheduler, Generation, ToolTask)
with the tool calls a conversation makes: a machine call
(`Photon.MachineTools.Call`: `Machines.start/1`'s own commit, the park on
the op's signal, the recheck, the claim, the offline give-up, and
`cancel_tx/2` in every commit that ends the call another way), a plain
tool that isn't safe to rerun, since step 3 the routine behind a
schedule (`Photon.Schedules.Routine`), which may repeat and which the
owner may edit or delete from the project page while a firing is in
flight, and since step 4 a thread's `ask_blip` call
(`Photon.Threads.Tools.AskBlip` over `Photon.Questions`: the ask's own
commit, the park on the question's signal, the checks and the escalation
to the owner, the withdraw when the call ends another way) with Blip's
side reduced to the question's carrier, Blip's answer or pass and the
owner's answer, plus the settle hook (`Durable.settled/3`). Faults: hub
crashes, Scheduler-only crashes, step crashes, a tool's code raising,
user Stops, the owner's edits and deletes, failing model requests, a
machine that is offline when the call checks, and the op finishing, or
an answer arriving, at any time.

Properties: one active run per conversation; one `tool_result` per tool
task and per stored call; bottom-up abort, and a stopped task ends
aborted; unsafe tools run at most once; placed input belongs to a live run
and settles; queued input leaves the inbox, and a Stop keeps a routine's
prompt; nothing stays running; a machine call records one result, an
op's result reaches at most one tool result, a call that has ended leaves
no row that may still start its op, and every row closes; one routine
carries a schedule at a time, no firing lands after an edit or delete
replaced its routine, each firing happens once, and a replaced routine
ends aborted; the settle hook runs once per settle; an ask call has one
question, answered at most once and never after it was withdrawn, and no
call that has ended leaves its question open; an answer always reaches a
call still waiting, and a question Blip didn't handle reaches the owner.

Details: `specs/tla/Durable.md`.

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

Its `-bug-*` configs are expected to fail: each puts back one defect with
a switch in `Bugs` and shows the property that catches it. A node that
doesn't list `"ops:2"` in its capabilities (step 2; `"ops:1"` before it)
is reported as outdated and gets no operations, and a call parked on it
ends with the outdated message; the spec doesn't model capabilities.

Details, the action-to-code map, per-config results and how the built
code compares with the spec: `specs/tla/HubOps.md`.

### `Executor.tla`

The node side of the protocol, opened up: the executor's handlers
(`op.start`, `op.cancel`, `op.ack`, checkpoints, reports, `:DOWN`, the
start-up scan) as ordered effects, so it can crash after any prefix of
them; its journal; the `Ops.Shell` processes it owns, with their calls
into it; and the commands with their process groups, background children
and `exit`, `pid`, `stopped`, `canceled` and `unstarted` files. The hub is a stand-in that follows
the plan's hub rules. Faults: executor crashes inside any handler,
operation process crashes, abrupt node crashes (commands survive), node
stops (shells kill their commands), dropped connections, extra `op.start`
pushes, cancels, and commands that leave background children or never
exit.

Properties: a command starts at most once; once the hub has a result,
nothing of the command is running; the result says what happened
(`completed` only for a command that exited on its own, `canceled` only
after a cancel, `failed` only after a fault); every op gets its result, a
cancel ends even a command that would run forever, and every finished
entry is forgotten.

Like `HubOps`, its `-bug-*` configs are expected to fail, the E1 and K2
ones (`-bug-cancel-marker`, `-bug-orphan-reattached`) among them.

Details: `specs/tla/Executor.md`.

### Property tests

| App | File | What it checks |
| --- | --- | --- |
| core | `sse_property_test.exs` | `SSE.parse` gives the same payloads however a stream is cut (well-formed and arbitrary streams, bare CRs included) and never raises |
| core | `llm_stream_property_test.exs` | an answer streamed over HTTP in any chunks gives `LLM.stream/3` the same result and events as the pure fold of the whole body |
| core | `message_property_test.exs` | `Message.arguments` never raises and decodes objects exactly; text/parts agree; every conversation (built from plain `Message` values) encodes as Responses input without raising |
| core | `output_property_test.exs` | `Output.bound` gives valid UTF-8 and the documented head/tail/marker shape; `sanitize` only replaces invalid bytes (moved from the node in step 1, with `PhotonCore.Output`) |
| node | `journal_property_test.exs` | step 1: an operation's journal entry survives a crash at any point of a write (torn temporary files, a crash between sync and rename): `read/2` returns the last entry fully written, or none, and the next write lands |
| hub | `durable_context_property_test.exs` | `Context.messages` pairs calls and results, sees nothing before the newest reset, and shows a result that directly follows its call |
| hub | `durable_schema_property_test.exs` | `Schema.validate` never raises on the real tool schemas or on JSON Schema beyond its subset, and agrees with an independent reading of the subset |
| hub | `machine_ops_property_test.exs` | step 1: op rows under duplicated, stale and foreign snapshots, unknown ops, reconnects, cancels and claims, against `Photon.Machines` and the database: a row only moves forward, so an op finishes at most once; its signal fires exactly when it leaves `open`; `op.ack` only for finished or closed rows (or none); no `op.start` for a canceled row; a result is claimed at most once |
| hub | `durable_model_property_test.exs` | model-based test of the harness (submit, steer, follow-up, retried request IDs, the `go` signal, abort, full and scheduler-only restarts): one active run; retried requests submit once; once quiet, every submission settled and every call has one result; the transcript stays well formed across scheduler restarts; an abort before the task module is loaded still settles |

Retired with the code they checked: the node's `context`, `inbox`,
`store`, `session` and `coordinator_replay` property tests (node
sessions), the hub's `node_sessions_property_test.exs`, and core's
`chat_completions_property_test.exs` (the model client speaks the
Responses API now) and `message_property_test.exs`'s `MockAgent`
conversations.

All of them run by default. Properties tagged `:known_bug` (none at the
moment) are excluded from the default run.

Each app's tests are laid out by layer: `test/core` (pure modules),
`test/boundary` (the APIs and their processes, against the database or a
node in a temporary directory), `test/web` on the hub (the node channel,
LiveViews, controllers and plugs), `test/property`, and on the hub
`test/integration` (a hub with a real node). Some rules the regression
tests pin are also tested on the pure modules: F8 on `Turn.round_limit/0`
and `Turn.not_run/1`, F9 and node-op-stale-registry on
`Executor.Rules.down/3`, and H7 on `Wait.offline_message/3`.

## How to run

ExUnit, in each app (the toolchain wrapper pins Elixir 1.20.4 / OTP 28):

```sh
cd apps/core && ~/.local/bin/mx mix test
cd apps/node && ~/.local/bin/mx mix test
cd apps/hub && ~/.local/bin/mx mix test
```

`mix test test/property` runs only the properties. `PHOTON_PROPERTY_RUNS=250`
raises the run count of the run-heavy model properties (hub durable model,
hub machine ops). `mix test --include known_bug` would also run properties
pinning open bugs.

TLC (TLA+ tools 2.19 at `~/.local/share/tla/tla2tools.jar`), from
`specs/tla`:

```sh
java -XX:+UseParallelGC -cp ~/.local/share/tla/tla2tools.jar tlc2.TLC \
  -workers auto -deadlock -metadir /tmp/tlc/<Cfg> -config <Cfg>.cfg <Spec>.tla
```

where `<Spec>` is `Durable`, `HubOps` or `Executor` and `<Cfg>` is one of
its `.cfg` files. Add `-lncheck final` for configs with `PROPERTIES`.
`-deadlock` is needed because every modeled behavior ends (the `HubOps`
and `Executor` configs also turn deadlock checking off themselves). The
`Durable-bug-*`, `HubOps-bug-*` and `Executor-bug-*` configs are meant to
fail; each spec's notes list the property each one breaks.

To run every config of every spec:

```sh
cd specs/tla
for cfg in *.cfg; do
  spec=${cfg%%-*}; spec=${spec%.cfg}
  extra=""; grep -q '^PROPERTIES' $cfg && extra="-lncheck final"
  java -XX:+UseParallelGC -cp ~/.local/share/tla/tla2tools.jar tlc2.TLC -workers 6 \
    -deadlock $extra -metadir /tmp/tlc/${cfg%.cfg} -config $cfg $spec.tla | tail -3
done
```

## Results

### Machine skills, no spec change (2026-10-07)

A follow-up to the five steps (`docs/plans/machine-skills.md`) lets a
skill be turned on for a machine as well as for Blip or a project. A
machine's skills are offered to Blip and every thread, listed under the
machine in their prompts, and `load_skill` accepts them. No spec changed
and TLC wasn't run. Section 11 of the plan gives the reasons:

- There is no new process, task kind, timer, signal or protocol message,
  and nodes don't change: nothing about skills reaches a node.
- Every write is a commit of a kind that already exists. Turning a skill
  on or off for a machine inserts or deletes one `skill_enablements` row,
  as a Blip or project toggle does; the machine is only a new form of the
  `scope` string (`"machine:<id>"`), so there is no migration either.
- `load_tx/3` still reads what it offers inside the commit that records
  the tool's result, so a load is ordered against a toggle by the Store,
  as step 3 argued for project and Blip skills.
- Prompts are rebuilt from rows at each model request, and `Durable.tla`
  doesn't model them.

The one new read that the Store doesn't order is which machines the hub
knows (`Photon.Machines.known/0`), which comes from the node keys and
the registry, written outside the Store. Its worst case is a load that
runs while its machine is being removed and still returns the skill.
That costs nothing: the text is instructions, and the next request's
prompt no longer lists the skill, which tells the agent to stop
following it. A spec change would be needed for a tool that turns
machine skills on from inside a run, or for anything that sends skills
to nodes; neither exists.

The new claims are each one read or one commit, checked by boundary and
LiveView tests in `apps/hub`:

- A removed machine's skills are hidden and come back with the machine.
  `test/boundary/skills_test.exs`: "a removed machine's skills are
  hidden until it is installed again" (after `NodeKeys.revoke/1` and
  again after `forget/1`, `scopes/1`, `list/0`, `machine_skills/0` and
  `load_tx/3` leave mm1's skills out, enabling one for it is refused, and
  after `NodeKeys.issue/2` all four have them back); "a machine the hub
  doesn't know is refused". `test/boundary/skill_tools_test.exs`: "every
  prompt lists it under its machine, and a removed machine's group goes"
  (Blip's and a thread's prompts). `test/web/live/skill_live_test.exs`:
  "each known machine has a switch, and a removed one doesn't",
  "machines installed and removed while the page is open come and go",
  "a machine reinstalled under its name keeps its switch on", "a machine
  removed since the page loaded is refused with a flash".
  `test/web/live/skills_live_test.exs`: "a removed machine drops out of
  the line".
- A load finds the agent's own skill first, then a machine's, inside its
  commit. The decision is pure, `Photon.Skills.Rules.find_offered/2`, in
  `test/core/skills/rules_test.exs` ("the own set wins over a machine
  that has the same skill", "names every machine that has it, in the
  order given", and the not-found cases). `test/boundary/skills_test.exs`
  checks it through the commit once: "load_tx/3 loads a machine's skill
  for Blip and for a project, naming the machines", and the removal
  case above. `test/boundary/skill_tools_test.exs`, through the scripted
  models: "a thread in a project with no skills lists and loads a
  machine's", "Blip lists and loads a machine's skill", and "turned off
  between two messages, it is no longer listed and won't load".
- Each machine holds at most 30, apart from Blip and other machines
  ("each machine takes at most 30 skills, apart from Blip and other
  machines"; on the page, "the 31st skill on a machine is refused with a
  flash"), and deleting a skill deletes its machine rows ("deleting a
  skill deletes its machine rows").
- Prompts don't change as machines connect and disconnect:
  `test/boundary/machines_test.exs`, "keeps its order while a machine
  connects and disconnects", and `test/core/machines/roster_test.exs`,
  "the same IDs in the same order whichever machines are connected". A
  hub with no machine skills sends the prompt it sent before:
  `test/core/skills/prompt_test.exs`, "with no machine skills, is the
  text it was before machines had skills, byte for byte".

### Step 5: ambient mode, no spec change (2026-10-07)

Step 5 adds ambient mode (`docs/plans/step-5-ambient-mode.md`): two
durable timers, a digest every few hours and a daily review, each
posting at most one message into Blip's conversation, and digest items
collected while the setting is on. No spec changed and TLC wasn't run.
Section 13 of the plan gives the reasons, and `specs/tla/Durable.md`
("What changed in build step 5") repeats them against the spec: an
ambient timer is a routine, which `Durable.tla` already models with its
edits and deletes (`RoutineFire`, `OwnerEdit`, `OwnerDelete`, and
`NoFireAfterRetire`, `FireOncePerSlot`, `RetiredEnds`); nothing commits
outside a step's fence on a task's behalf, as step 4's ask did; and an
item from a settle is written in the settle hook's commit, which
`HookOnce` covers.

What step 5 claims beyond that is each one commit's work, true by the
serial commit line and checked by boundary tests instead:

- A digest posts its message and marks every item it read as carried in
  one commit, so no item is reported twice; the commit that settles
  Blip's run on it deletes them, or gives them back when the run failed,
  so none is lost (`test/boundary/ambient_test.exs`: "posts what is new
  with the smaller changes, and uses up every item once Blip answers",
  "a digest whose run fails gives its items back for the next one", "a
  review whose run fails clears its threads' marks"; a second digest
  while the first waits skips and keeps the items).
- Turning ambient mode off retires both timers, deletes the items,
  withdraws a queued digest or review and clears that review's marks in
  one commit ("turning it off retires both timers, deletes the items and
  withdraws a queued digest", "turning it off withdraws a queued review
  and clears its threads' marks").
- A firing step of a retired timer commits nothing ("a firing step of a
  timer replaced meanwhile commits nothing", "a firing step after
  ambient mode was turned off commits nothing"), and a timer waiting for
  its time still waits after a restart.
- Every collector reads the mode in its own commit, so nothing is
  collected while it is off (the cases with ambient mode off in
  `signals_test.exs`, `threads_test.exs`, `projects_test.exs` and
  `schedules_test.exs`), and a settle makes one item per thread, at the
  run's end ("a run that answers two queued inputs makes one item, at
  its end"). Every item is keyed by its subject, so the table holds at
  most one row per subject ("collect_tx/2 keeps one row per subject").
- `collect_tx/2` and the timer's `on_fail/3` run on the harness's hook
  paths and are total ("collect_tx/2 makes one row per key, announces
  each insert, and is total"; "on_fail/3 for a task the doc no longer
  names writes nothing"; "a firing that raises stops the timer and says
  so, until the next save").

The one change to the harness, `Durable.Context`'s rule for earlier
runs that carry an `"older"` stub, is in a pure function and covered by
`test/core/durable/context_test.exs`. The end-to-end test
(`test/integration/machine_tools_e2e_test.exs`) walks a digest, a second
one with nothing new, the review and turning the mode off against a real
node.

### Step 4: `ask_blip` and the settle hook in `Durable.tla` (2026-10-06)

Step 4 lets a thread ask Blip a question with `ask_blip` and wait,
durably, for the answer, which comes from Blip or, through Blip or the
hub's escalation, from the owner; and every run's end reaches Blip
through a new settle hook in the harness. `Durable.tla` was extended
before the code, from the plan
(`docs/plans/step-4-blip-as-coordinator.md`, sections 3.1, 3.3, 4 and
14), with the call (`QAsk`, `QPark`, `QResume`, `QEscalate`,
`QParkSig`), Blip's side reduced to the question's carrier (`BlipPlace`,
`BlipSettle`, `BlipAnswer`, `BlipPass`), `OwnerAnswer`, the withdraw on
every other way the call ends, and the settle hook in every commit that
settles a run's input. TLC 2.19 on the shared 12-core machine (load
average around 40 from other work):

- The three new configs pass: `Durable-ask.cfg` (an ask call with every
  crash kind and a Stop; 420,090 distinct states, 26s),
  `Durable-ask-mixed.cfg` (an ask call and a machine call parked in one
  round, a hub crash and a Stop; 3.7M, 4m21s) and
  `Durable-ask-live.cfg` (liveness with every crash kind; 420,090,
  7m23s). TLC found no problem in sections 3 and 4 of the plan: the
  ask's own check keeps a Stop from leaving a question open, one answer
  lands per question and none after a withdraw, an answer always reaches
  a waiting call, and a question Blip didn't handle reaches the owner.
- The two bug configs fail as they should: `Durable-bug-ask-unfenced`
  (the ask commit without its task check) on `NoOpenQuestionAfterCall`
  in 9 states, through a step a Scheduler crash orphaned, and
  `Durable-bug-answer-twice` (the owner's answer without the status
  check) on `AnswerOnce` in 8. Copies of the spec with one rule broken
  each fail the property meant to catch it: no withdraw in
  `on_interrupt/2`, a rerun that asks again, no escalation, an answer
  without its signal, Blip's answer to a withdrawn question, a question
  with the owner taken for an answer, and a settle hook run twice.
- The 19 older passing configs, rerun with the new constants at their
  old values, reach exactly their old state counts, and the two older
  bug configs fail with their old traces. `HookOnce` joined the safety
  set of the six main safety configs.

Modeling settled four details the plan's section 14 had put differently
or left open, now fixed in the plan: the carrier can be withdrawn; Blip
may answer or pass a question at any time after it was asked;
`PlacedSettles` with an ask call needs the owner to answer eventually (a
question with the owner waits with no limit, by design), so
`Durable-ask-live.cfg` uses `SpecOwnerAnswers`; and the answered branch
of `resume/2` is a plain ok result. Thread state, the other signals and
the activity log are left out: they are derived at read time or written
in commits the spec already bounds. Per-config counts and traces:
`specs/tla/Durable.md`.

### Step 3: schedules in `Durable.tla` (2026-10-06)

Step 3 makes schedules owner-facing: a routine repeats, and the owner can
edit or delete its schedule from the project page while a firing is in
flight. `Durable.tla` was extended before the code, from the plan
(`docs/plans/step-3-skills-and-schedules.md`, sections 3.3, 3.4 and 10),
with `OwnerEdit`, `OwnerDelete`, a repeating `RoutineFire`, the
invariants `OneCarrier`, `NoFireAfterRetire` and `FireOncePerSlot`, and
the liveness property `RetiredEnds`. TLC 2.19 on the shared 12-core
machine (load average around 40 from other work):

- The three new configs pass: `Durable-schedule.cfg` (firings into
  Blip's or a thread's conversation, an edit and a delete, every crash
  kind and a Stop; 7.3M distinct states, 5m17s),
  `Durable-schedule-thread.cfg` (each firing starts a thread, so there is
  no request ID to dedupe on; 9.4M, 8m22s) and
  `Durable-schedule-live.cfg` (1.2M, 43m27s with the temporal check).
  TLC found no problem in the plan's rules: the step fence alone keeps a
  firing from landing after its schedule was edited or deleted, or
  twice.
- The two bug configs fail as they should: `Durable-bug-edit-keeps-old`
  (an edit that doesn't mark the old routine) on `OneCarrier` in 2
  states, and `Durable-bug-fire-after-retire` (a fire commit that ignores
  the abort mark) on `NoFireAfterRetire` in 8. A copy of the spec whose
  fire commit isn't fenced on its start fails `FireOncePerSlot` in 10
  states, and an edit that keeps the old routine fails `RetiredEnds`.
- The 15 older configs, rerun with the new constants at their old
  values, reach exactly their old state counts.

`Durable-schedule.cfg` leaves out the user input the plan first gave it:
with it, TLC passed 160M states in two hours without finishing. Times are
left out of the model, so `Rules.arm/4` and `fired_through/3` (an edit
neither skips nor repeats a firing) are covered by ExUnit, not TLC.
Per-config counts and traces: `specs/tla/Durable.md`.

The implementation review found one case those tests missed: a repeating
schedule saved as Once at the slot it had just fired got `:finished`
from `arm/4`, and the edit left its old routine running. The fix retires
the routine and arms none, which on the modeled variables is
`OwnerDelete`'s step, so the spec didn't change. A new liveness config,
`Durable-schedule-retire-live.cfg`, checks that a routine retired with
no replacement ends `aborted` (394 distinct states, 2s), and
`test/core/schedules/rules_test.exs` and
`test/boundary/schedules_test.exs` now cover the edit.

### Step 1 review: E1 and K2 fixed (2026-10-06)

`Executor.tla` models the two fixes (the `canceled` marker, and
`terminate/2` killing any command on record for a snapshot still
awaiting its process), with the old behaviour as
`Executor-bug-cancel-marker` and `Executor-bug-orphan-reattached`, which
replace the two `-known-*` configs. `ResultTruthful` lost its exception
for canceled ops, and `Executor-faults.cfg` now checks `ResultPhysical`.
TLC 2.19 reran all 14 configs on the shared 12-core machine (load
average 37 to 50 from other work), 6 workers, or 11 for `Executor-two`:

- The 6 clean configs pass: `Executor-two.cfg` (two ops, 90.8M distinct
  states, as before, 17m10s), `Executor-faults.cfg` (4.4M, 2m18s), `Executor.cfg`
  (375K with liveness, 1m55s), `Executor-two-live.cfg` (258K, 2m07s),
  `Executor-node.cfg` and `Executor-cancel.cfg` (116K each, 41s and
  31s).
- The 8 bug configs each fail on their property within 2 seconds, with
  traces of 10 to 23 states: E1's in 23 states (`ResultTruthful`) and
  K2's in 13 (`ResultPhysical`), as the `-known-*` configs did. With
  their switches off, the same two shapes pass.

Per-config counts and traces are in `specs/tla/Executor.md`.

### Build step 1, PR B (2026-10-05)

TLC 2.19 on the shared 12-core machine, the CPUs mostly idle. Every
config of the three specs was run:

- `Durable.tla`, 15 configs, 6 workers: every one passes. The largest are
  `Durable-parallel.cfg` (1.9M distinct states, 46s), `Durable-routine.cfg`
  (862K, 23s) and `Durable.cfg` (791K, 17s). The four configs whose tools
  didn't change (`-stranded`, `-abortfail`, `-maxrounds`, `-schedcrash`)
  reach exactly their old state counts. Five copies of the spec with one
  of the machine call's rules broken each fail on the property meant to
  catch it.
- `Executor.tla`, 14 configs, rerun on the merged code after G1: the 6
  clean ones pass, the largest being `Executor-two.cfg` (two ops, 90.8M,
  16m29s with 11 workers), `Executor-faults.cfg` (4.6M, 2m35s) and
  `Executor.cfg` (371K with liveness, 1m41s). The 6 bug configs and 2
  known configs each fail on their property within 3 seconds, with
  traces of 5 to 23 states.
- `HubOps.tla`, 19 configs, rerun unchanged with 11 workers: every one
  ends as in PR A, the clean ones with the same state counts and the bug
  configs with the same traces; the slowest were `HubOps-errors.cfg`
  (9m08s) and `HubOps-two.cfg` (8m30s).

Every config finishes within 15 minutes. Per-config counts and traces are
in each spec's notes.

### HubOps (step 1, PR A, 2026-10-05)

`HubOps.tla` has 19 configs. The 7 clean ones pass, the largest being
`HubOps-two.cfg` (two calls, 49.3M distinct states, 27m40s),
`HubOps-errors.cfg` (1.8M, 23m58s, with every liveness property) and
`HubOps.cfg` (10.2M, 5m08s). Each of the 12 bug configs fails on its
property within a few seconds, with a trace of 5 to 24 states. Times are
on the shared 12-core machine with 4 workers (2 for the bug configs).
Per-config counts and traces: `specs/tla/HubOps.md`.

They were run against the plan, before the code. When the code was done,
it was compared with the spec action by action; no rule the spec models
had changed. The differences in shape (for example `resume/2` reading the
row before its commit, or a request reaching a channel before its
`:joined`) are written up in `HubOps.md` with why the spec still covers
them.

### Final review (2026-10-04), before build step 1

After the verification pass and the three refactors, everything was run
again: in each app `mix precommit` (compile with warnings as errors,
unused-lock check, format, `credo --strict`, tests with warnings as
errors) and `mix dialyzer`; the node also compiles in `prod`, as
packaging does. Core 159 passed (16 properties, 143 tests, the custom
Credo checks' tests included), node 125 (16 properties, 109 tests), hub
289 (13 properties, 276 tests). The node and hub suites passed three runs
in a row, and the property suites again with `PHOTON_PROPERTY_RUNS=200`.
All 56 TLC configs of `NodeSync`, `Durable` and `Coordinator` were
re-run: the 55 that should pass did, and `Coordinator-witness.cfg`
violated its six witness invariants, as it should. One bug was found and
fixed with tests (core-negative-retry-after in the core table).

### The verification pass

ExUnit, final run (after the review): core 34 passed (15 properties, 19
tests), node 49 passed (15 properties, 34 tests), hub 80 passed (13
properties, 67 tests). Fail-first check: the new regression tests were run
against a copy of the apps with the original `lib/` restored. 45 of the 49
new tests failed there for the reason they target (core 10 of 12, node 16
of 17, hub 19 of 20); the 4 that passed pin behavior the fixes must keep.
The review's five new node tests were checked the same way: four failed
for the reason they target, and the fifth pins behavior the fix keeps.

## Findings, triage and fixes

"Test" names the regression tests (file: test name). "Spec" names the
config that reproduced the bug. A bug config whose name starts with
`Durable-bug-`, `HubOps-bug-` or `Executor-bug-` puts the bug back and fails; any other
config is a regression check that passes. "Retired" means the code, its
fix and its tests were deleted with node sessions or the old model client;
the spec column then names the config as it was.

### Node: operations, sessions, replication

| ID | Bug | Fix | Test | Spec |
| --- | --- | --- | --- | --- |
| Coordinator F3 | a shell command could start twice: it started before its `process` checkpoint was stored | the shell asks its owner (the executor since step 1, the coordinator before) to persist the checkpoint by a call (`Owner.checkpoint/2`) and starts only on `:ok` (`:cancel` if the journal says canceled; otherwise it stops and is started again from the journal) | `shell_test.exs`: "a command doesn't start until its owner has stored the checkpoint" | `Executor-bug-double-exec` |
| Coordinator F8 | a cancel that reached a shell before its PID was known didn't kill the command, so the stop (now the cancel) never finished | the `pid` handler kills the group if a cancel came first | `shell_test.exs`: "a cancel that arrives before the command's PID is known still kills it" | `Executor-bug-cancel-before-pid` |
| Coordinator F9 | a crashed operation process went unnoticed; its call never got a result | the owner monitors operation processes; a `:DOWN` fails a live operation (a clean exit before starting is restarted, once: `Executor.Rules.down/3`) | `executor_test.exs`: "an operation process killed with :kill fails its operation", "a reattached command shut down before its result is restarted once and reported stopped"; `executor/rules_test.exs`: "a crash fails the operation" | `Executor-bug-op-crash` |
| Coordinator F11 | a shell reattached after a node restart waited for background children of a command that had exited | `poll_recovered/1` checks the exit file first, then kills the group | `shell_test.exs`: "a reattached command that exits leaving background children finishes" | `Executor-bug-bg-reattach` |
| K1 (known upstream gap) | a node crash after the `process` checkpoint but before the PGID one left the command running unwatched (the session went `idle`; now the op would fail while it runs) | the wrapper writes the command's PID to a `pid` file; recovery reads it when the snapshot has no PGID | `shell_test.exs`: "a command started just before a crash is found through its pid file"; `executor_test.exs`: "the scan finds a command started just before a crash through its pid file" | `Executor-bug-pid-file` |
| node-op-stale-registry (review) | `Registry.lookup/2` still lists a process that has just exited, so `Ops.add/2` could resend to a dead operation process; the owner's monitor got `:noproc` and failed the operation though its command never ran | `Ops.add/2` starts a new process if the listed one isn't alive; `:noproc` counts as a clean exit (restarted once) | `shell_test.exs`: "an operation whose old process has just exited is started again"; `executor/rules_test.exs`: "a clean exit before the result restarts once, canceled if the entry says so" | - (no registry in the model) |
| NS-1 (retired) | `Connection.replay/3` read the log twice when nothing was new, so the hub could stay a record short until the next reconnect | the watermark came from the same read | retired | `NodeSyncReplayRace` |
| NS-2, Coordinator F7 (retired) | `resume_all` skipped a session whose input was logged before its `running` record | `Harness.working?/1` also counted an input after the last response or stop | retired | `NodeSyncResume`, `Coordinator-bug-not-resumed` |
| NS-3, Coordinator F6 (retired) | inputs in a crashed coordinator's mailbox were lost until the next reconnect | delivery became a call answered once the input was persisted, retried with the successor | retired | `NodeSyncMailbox`, `Coordinator-bug-crash-loses-input` |
| NS-4, Coordinator F5 (retired) | an input sent to a coordinator stopping on `:idle_stop` died with it | the same synchronous delivery | retired | `NodeSyncIdleStop`, `Coordinator-bug-idle-stop-loses-input` |
| NS-6 (retired) | a run whose last response had no text reported the previous run's answer | an accepted input cleared the last answer | retired | `NodeSyncStaleAnswer` |
| NS-8, Coordinator F2, node-stop-lost-on-crash (retired) | a hard stop logged without its `stopped` record was forgotten on restart | replay re-armed the stop | retired | `NodeSyncStop`, `Coordinator-bug-stop-forgotten` |
| Coordinator F1 (retired) | a crash in the handler that started a turn orphaned the model request | the request task was linked to its coordinator | retired | `Coordinator-bug-orphan-llm` |
| Coordinator F4 (retired) | an input accepted while a hard stop was finishing was never answered | such input was held and persisted after `stopped` | retired | `Coordinator-bug-stop-swallows-input` |
| Coordinator F10 (retired) | a recorded call whose tool no longer resolved never finished | such a call got a generic result | retired | `Coordinator-bug-tool-vanish` |
| NS-9 (review, retired) | the hub's stop was still a plain message, lost with a coordinator's mailbox | stops went through the same call as inputs | retired | `NodeSyncStopLost` |
| node-inbox-heartbeat-parameters (retired) | a heartbeat control with parameters was accepted | rejected like a hard stop with parameters | retired | property |
| node-inbox-poison-content (hardening, retired) | the inbox accepted any list as content | content had to be text or well-formed parts | retired | property |

### Hub: durable harness, node sessions, assistant

| ID | Bug | Fix | Test | Spec |
| --- | --- | --- | --- | --- |
| Durable F4, hub-abort-strands-submission | input queued behind a run that failed, hit the round limit, crashed, or was stopped stayed queued forever | failing runs continue with the inbox; when the Scheduler fails or aborts a run, `Durable.continue_inbox/2` starts the next one | `durable_regression_test.exs`: "input queued behind a run whose model request fails still gets answered", "input sent while a stopped run is still being aborted starts the next run"; property "once the harness is quiet, every submission has settled" | `Durable-stranded`, `Durable-stop-stranded` |
| Durable F6 | Stop withdrew queued background input (then node reports and routine prompts) | `Durable.abort/2` takes `:withdraw`; `Assistant.stop` withdraws only the user's input | `machine_tools_test.exs`: "Stop withdraws the user's queued messages but keeps background input" | `Durable-withdraw` |
| Durable F7 | a stopped task whose step returned first ended `failed` with "ended without a transition" | `Scheduler.fail/2` leaves a task marked for abort to `stop_aborted` | `durable_regression_test.exs`: "a run stopped while its step is finishing ends aborted, not failed" | `Durable-abortfail` |
| Durable F8 | calls in the last assistant entry of a run that hit the round limit got no result | one "Not run" `tool_result` per call in the same commit | `durable_regression_test.exs`: "a run that hits the round limit gives every stored call a result" | `Durable-maxrounds` |
| Durable F10, hub-scheduler-restart-duplicates-steps (also H2) | a Scheduler-only restart left old steps running and restarted their tasks; both committed (duplicate turns and tool runs) | step commits are fenced: `Tx.transition/4` applies only while the task is `running` with the `updated_at` the step started with | `durable_regression_test.exs`: "a step left over from a scheduler restart can't commit"; property "the stored transcript keeps each call's results within its round across scheduler restarts" | `Durable-schedcrash` |
| Durable F10b (found while modeling the F10 fix) | the first fence compared `runs`, which restarts with each phase, so a leftover step could commit into a later start of its phase | fence on `updated_at` instead | `durable_regression_test.exs`: "a leftover step can't commit into a later run of its phase" | `Durable-schedcrash-ok` (`PlacedTracked`) |
| hub-function-exported-unloaded | `on_abort`/`on_fail`/`replay` were looked up with `function_exported?/3`, false for an unloaded module, so an early abort skipped `on_abort` and left input `placed` | `Code.ensure_loaded?/1` first | `durable_regression_test.exs`: "a run aborted before its task module is loaded still settles its input"; the property of the same name | - |
| hub-schema-raises-beyond-subset (hardening) | boolean subschemas and enums of objects crashed validation; type lists accepted anything | boolean subschemas, type lists and non-text enums handled | `durable/schema_test.exs`: "boolean subschemas allow anything or nothing", "an enum of objects reports a mismatch instead of raising", "a list of types accepts any of them and rejects the rest" | property |
| Durable F1 (retired) | the node's answer could come back in the tool result and again as the watcher's report | `NodeWork.resume/2` decided inside the result's commit (the `{:commit, fun}` tool result, which machine calls now use to claim their result) | retired | `Durable-double` (now checks `OneResultPerCall` and `ClaimedOnce` for machine calls) |
| Durable F2 (retired) | a Stop between the watcher abort and the tool result lost the answer | the same fix | retired | `Durable-stop-watcher` |
| Durable F3 (retired) | a Stop or crash after the session started but before the watcher existed left the work unwatched | `Tool.on_interrupt/2`, called by `ToolTask.on_abort`/`on_fail`; machine calls use it to cancel their op | retired | `Durable-stop`, `Durable-crash` (now check `NoOpenRowAfterDone` for machine calls) |
| Durable F9 (retired) | a watcher whose step crashed failed for good | `on_fail/3` may return `:retry`; nothing uses it now | retired | `Durable-crash-watcher` |
| NS-5, Durable F5 (also H3, retired) | `ingest/4` settled inputs and fired their signal in two commits | one Store commit with `Tx.signal/3` inside; an op's result and its signal have always been one commit (hub rule 4) | retired | `NodeSyncSignal`, `Durable-delivery` |
| NS-7 (retired) | an input the node refused could be pushed again, run, and stay `failed` on the hub | pushes only of a still-queued input, once per connection | retired | `NodeSyncReject` |
| hub-ingest-raises-on-malformed-record (hardening, retired) | a malformed node record crashed the ingest (and the channel, on every replay) | such fields were ignored | retired | property |

### Step 1: the operation protocol

`HubOps.tla` found H1 to H8 in the plan's first version of the protocol;
each was fixed in the plan before the code was written, so the code never
had them. The tests pin each fix in the code. H2 is a property of how the
code is built (the channel's reads are `Durable.commit/1` calls, so they
wait for a commit in progress), and no test can force the interleaving.
`Executor.tla` found E1 and K2 in the code as built. G1 fixed part of
K2 (a crash while polling); G2, after the PR B review, fixed E1 and the
rest of K2.
Test files are under `apps/hub/test` unless they name the node.

| ID | Problem | Fix (plan section 2.3) | Test | Spec |
| --- | --- | --- | --- | --- |
| H1 | an `op.start` built by `Machines.start/1` before the result was recorded, and pushed after the `op.ack`, ran a finished command again | hub rule 2: only the channel builds `op.start`, from the row as it is when it pushes (`Machines.push_for/2`); a `{:command, "op.start", _}` is dropped | `boundary/machines_test.exs`: "nothing once the row has finished: the stale-start trace"; `web/channels/node_channel_test.exs`: "an op.start built anywhere but the channel is dropped" | `HubOps-bug-stale-start` |
| H2 | a join that read the rows around the abort commit missed its `cancel`, and the command ran on | hub rule 2: the channel's reads go through `Durable.commit/1` and wait for a commit in progress | by construction (see above) | `HubOps-bug-unserialized-read` |
| H3 | a rolled-back Stop let a canceled op start, because the node answered "canceled before it started" without keeping it | node rule 7: that answer is journaled and kept until `op.ack` | node `boundary/executor_test.exs`: "a cancel before the start is journaled, so a later start runs nothing"; `integration/machine_tools_e2e_test.exs`: "an op stopped while the node was away is canceled before it starts when the node joins" | `HubOps-bug-cancel-unjournaled` |
| H4 | a finished row whose call was stopped kept its snapshot (up to 5 MB) for good | hub rule 7: `cancel_tx/2` closes a finished row and drops it; `abandon_tx/2` claims it | `boundary/machine_tools_test.exs`: "Stop after the result came in, before the call claimed it, closes the row without it"; `boundary/machines_test.exs`: "a result that came in first is closed and dropped", "an op that finished meanwhile is claimed instead" | `HubOps-bug-keep-finished` |
| H5 | a step orphaned by a Scheduler-only crash inserted its row after Stop, leaving an op nothing would cancel | hub rule 9: the insert happens only while the task is unfinished and not marked for abort | `boundary/machines_test.exs`: "inserts nothing for a task marked for abort, or finished"; `boundary/machine_tools_test.exs`: "a stopped task's op isn't recorded" | `HubOps-bug-unfenced-insert`; `Durable-schedcrash-ok` (`NoOpenRowAfterDone`) |
| H6 | an offline give-up that raced a reconnect only set `cancel`, so the command the join had just started ran on | hub rule 7: `abandon_tx/2` sends `op.cancel` from inside its commit, like `cancel_tx/2` | `boundary/machine_tools_test.exs`: "the machine comes back between the offline check and the give-up: op.start went out, so the message hedges and the node gets op.cancel" | `HubOps-bug-abandon-silent` |
| H7 | the offline message said "the command didn't run" when the node had run it but no snapshot had arrived | hub rules 2 and 7: rows record `pushed`, and "didn't run" needs neither `pushed` nor `confirmed` | `core/machine_tools/wait_test.exs`: "says the command didn't run only when it was never pushed and never confirmed"; `boundary/machine_tools_test.exs`: the two offline tests | `HubOps-bug-offline-confirmed` |
| H8 | a call that ended in an error (a raise, or an error result after the row existed) left its row open for the next join to start | hub rule 10: every error result after the op ID cancels the op in its commit; a rescued raise runs `on_interrupt/2`; a rerun that finds the row parks | `boundary/machine_tools_test.exs`: "a raise after the op exists ends with an error, and cancels the op", "parks without checking the machine, even if it is now unknown"; `boundary/durable_test.exs`: "ends its call with an error, and its on_interrupt runs in the same commit" | `HubOps-bug-error-skips-cancel`; `Durable-crash` (`NoOpenRowAfterDone`) |
| rules the plan had | an early `op.ack`, a spawn before the journal, an `op.start` after a cancel, no `known` flag | hub rules 4 and 7, node rules 3 and 4 | `boundary/machines_test.exs`: "a result is stored with its signal, then acked", "a join resends op.cancel for a canceled row, and never op.start"; node `boundary/executor_test.exs`: "an operation the hub has seen but the node has no record of fails without running", "a cancel journaled before the command's start means it never spawns"; node `boundary/shell_test.exs`: "a command doesn't start until its owner has stored the checkpoint" | `HubOps-bug-ack-early`, `-bug-spawn-before-journal`, `-bug-start-after-cancel`, `-bug-no-known` |
| node rule 10 | a node stopped on purpose killed its running commands, and the resumed op reported a killed command `completed` (the wrapper records exit 143) | `terminate/2` writes a `stopped` marker before it kills, and `recover/1` checks it before the exit file | node `boundary/shell_test.exs`: "a command killed when its shell is shut down is reported as stopped, not completed"; node `boundary/executor_test.exs`: "a node stopped while a command runs reports the command as killed after it restarts" | `Executor-bug-stopped-marker` |
| E1 | a command killed by a cancel is reported `completed` (exit 143) when the executor or the node dies after the kill and before the `canceled` snapshot is journaled: the resumed shell's `recover/1` finds the exit file before it handles the `:cancel` that follows `Ops.add/2`. Low severity: the hub closes a canceled row without showing its result, unless the commit that canceled it rolled back | G2: the shell writes a `canceled` marker before a cancel's kill, and `recover/1` checks it before the `stopped` marker and the exit file and finishes the op as `canceled`; a fresh start removes it and `Journal.forget/2` deletes it | node `boundary/shell_test.exs`: "a command killed by a cancel is resumed as canceled, not completed", "a reattached command killed by a cancel is resumed as canceled", "a fresh start clears a canceled marker left by an earlier one"; node `boundary/journal_test.exs`: "forget/2 deletes the entry and the command's bookkeeping, and keeps its output" | `Executor-bug-cancel-marker` (fails `ResultTruthful`, which no longer excepts canceled ops) |
| K2 | a shell resumed after a node crash has no port to the command the previous VM started, so if it crashes its `terminate/2` kills nothing; the op fails and the command runs on unwatched. Low severity: it takes a node crash and then a crash in the shell's own code | G1: `terminate/2` killed a command the shell had reattached to (a crash while polling). G2: `terminate/2` kills the recorded process group (snapshot or `pid` file) whenever the port is open or the snapshot is still `awaiting` in phase `process`, so a crash in `recover/1` before it reattaches kills it too; the `stopped` marker comes first unless the `exit` file is already there | node `boundary/shell_test.exs`: "a resumed shell that crashes before it reattaches kills its command", "a resumed shell that crashes after its command exited leaves no stopped marker", "a reattached command is killed and reported as stopped when its shell is shut down"; node `boundary/executor_test.exs`: "a reattached command shut down before its result is restarted once and reported stopped" | `Executor-bug-orphan-reattached` (puts back G1's `terminate/2`; fails `ResultPhysical` through a crash in `recover/1`). `Executor-faults` now checks `ResultPhysical` too |
| G1 unstarted | an executor crash after it journaled a `process` checkpoint and before it answered left a shell that stopped without spawning, and the resumed op failed as "outcome unknown" though the command never ran | node rule 4: on `:ignored` the shell writes an `unstarted` marker before it stops; a resume with no process group, no `pid` file and the marker starts the command through the checkpoint again; every start removes the marker before its checkpoint, and `Journal.forget/2` deletes it | node `boundary/shell_test.exs`: "a command whose stored start was never confirmed runs once when resumed", "a stored start with no process group, pid file or marker fails as unknown"; node `boundary/executor_test.exs`: "a command whose journaled start the executor never confirmed runs once" | `Executor` and `-faults`, `-two` (`AtMostOnceExec` with the marker path; `Executor.md` records that it is reached) |

### Core: model client and message format

| ID | Bug | Fix | Test |
| --- | --- | --- | --- |
| core-sse-crlf-split | `SSE.parse` normalized CRLF in the buffer it returned and again on the next call, so a payload's trailing CR depended on where the stream was cut; bare CR wasn't a line end; every leading space was trimmed | WHATWG line endings (CRLF, LF, CR), a trailing CR held back, one space dropped, field name must be `data` | `core/sse_test.exs`: "a CR before a CRLF gives the same payload however the stream is cut", "the shrunk counterexample parses the same whole and cut at byte 8", "bare CR ends a line, and a CRLF split across chunks is one line ending", "only one space after the colon is dropped, and the field name must be data" |
| core-message-arguments-raises (hardening) | a call without `arguments`, or with non-text arguments, raised | missing means `{}`, an object is taken as is, anything else is an error | `core/message_test.exs`: "arguments never raises for a call without text arguments" |
| core-negative-retry-after (final review) | a negative `Retry-After` header became a negative `retry_after`, and `Process.sleep/1` raised on it, crashing the caller's request task instead of retrying | a negative value is ignored like any other malformed one, so the retry uses the usual backoff | `core/http_error_test.exs`: "ignores a negative retry-after, which no wait can honor"; `boundary/llm_test.exs`: "is retried with the usual backoff instead of crashing the caller" |
| core-stream-raises-on-malformed-chunks (retired) | Chat Completions chunks of unexpected shapes raised inside the stream fold | unexpected shapes were skipped (the Responses fold skips events it can't read: `core/responses/response_test.exs`, "events it doesn't know, or can't read, are skipped") | retired with `ChatCompletions` |
| core-mockagent-proxy-divergence (retired) | through the hub's mock proxy a tool image came back as a separate user message, which `MockAgent` took for a new prompt | `decode_messages/1` inverted `encode_messages/1` | retired with the proxy, `ChatCompletions` and `MockAgent` |
| core-decode-messages-raises (hardening, retired) | content that wasn't text or a list raised | unknown shapes were skipped | retired with `ChatCompletions` |

The findings marked "hardening" were reported as not likely real bugs:
current callers couldn't produce those inputs. The properties were valid
and the fixes small, so they were fixed rather than dismissed.

## Artifacts

Problems in the tests and models found while fixing, as opposed to bugs in
the code:

- The property "decoding an encoded conversation keeps every message's
  meaning" encoded the old, lossy decode (tool images moved into a user
  message) as expected. It went with `ChatCompletions`.
- The hub test "hands work to a node and returns a quick answer" relied on
  the tool winning a race against the watcher. It went with node work.
- `Executor-bug-cancel-before-pid.cfg` and `Executor-cancel.cfg` use
  `SpecUnboundedCommands` (commands may run forever), where `CallResult`
  can't hold without a cancel. They check `CancelTakesEffect`.
- `Executor.tla` first checked liveness at about 47,000 states a minute:
  TLC re-evaluated the effect fold lazily inside ENABLED and temporal
  checks. Binding it strictly, as `Coordinator.tla` had, made it about
  three and a half times faster with the same states.

The original verification notes also listed four modeling artifacts in
`Coordinator.tla` and two in `NodeSync.tla`, fixed before the findings
were reported; they went with those specs (in git history).

## Compatibility

- **Wire protocol**: build step 1 replaced the hub-node protocol with the
  operation protocol (`op.*` events, plan section 2), and PR B removed the
  session messages and the model relay. Build step 2 moved the
  capability to `"ops:2"`: a `shell` operation creates its missing working
  directory. A node without `"ops:2"` is reported as outdated. Nothing is
  migrated: the hub database and node installs are replaced.
- **Node journal**: one entry per operation, `<data_dir>/ops/<op_id>/op.json`,
  next to the shell's `out`, `err`, `pid`, `exit` and `stopped` files.
- **Hub database**: `machine_ops` is new in step 1; the node session
  tables are gone in PR B, with no drop migration (the database is
  deleted). Step 2 adds `projects`, `project_files` and `threads` in new
  migrations, and the database is deleted again.

## Limits

- Power loss isn't modeled: the journal and the database are fsynced
  before they are acted on, but a reader could see a write before its
  sync finished.
- `Executor.tla` leaves out journal write failures and unreadable entries
  (node rule 8), output, `view_image`, the frame budget and the sweep;
  ExUnit covers them (`executor_test.exs`). Its hub is a stand-in, and
  `HubOps.tla` leaves out executor and operation-process crashes, so no
  one spec has both a hub crash and an executor crash. E1 needed both to
  be visible to a model, which is why it was low.
- `Durable.tla` reduces the machine to its row and signal, and bounds a
  call's rechecks (`MaxRechecks`); `HubOps.tla` models the rest of the
  protocol. It models one schedule, without times, and bounds a
  repeating routine's firings (`MaxFires`). For `ask_blip` it reduces
  Blip's conversation to the question's carrier and leaves out Blip's
  reasoning, the texts, signal merging, thread state and the activity
  log; an ask call's checks are bounded like a machine call's until its
  carrier settles.
