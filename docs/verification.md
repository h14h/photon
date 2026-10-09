# Verification

Photon's harnesses are checked three ways:

- **TLA+ specs** in `specs/tla`, checked with TLC: `Durable` (the hub's
  durable harness, machine calls, schedules and `ask_blip`), `HubOps` (the
  operation protocol between the hub and a node, end to end) and `Executor`
  (the node's executor, journal, operation processes and commands).
- **Property tests** (StreamData) in each app's `test/property`.
- **Regression tests**: a deterministic ExUnit test per bug, written to
  fail on the code before its fix.

Each spec has `-bug-*` configs that put back one past defect with a switch
in `Bugs` and are expected to fail; the spec's notes in `specs/tla/*.md`
name the property each breaks and map the spec's actions to the code.

## What each spec covers

### `Durable.tla`

`Photon.Durable` (Store, Tx, Runtime, Scheduler, Generation, ToolTask) with
the tool calls a conversation makes: a machine call (`MachineTools.Call`:
the op row's commit, the park on its signal, the recheck, the claim, the
offline give-up, and the cancel in every commit that ends the call another
way); a plain tool that isn't safe to rerun; a schedule's routine
(`Schedules.Routine`), which may repeat and which the owner may edit or
delete mid-firing; and a thread's `ask_blip` call (`Threads.Tools.AskBlip`
over `Photon.Questions`), with Blip reduced to the question's carrier, plus
the settle hook (`Durable.settled/3`).

Faults: hub crashes, Scheduler-only crashes, step crashes, a tool raising,
Stops, the owner's edits and deletes, failing model requests, an offline
machine, and an op finishing or an answer arriving at any time.

Properties: one active run per conversation; one `tool_result` per tool
task and per stored call; bottom-up abort, and a stopped task ends aborted;
unsafe tools run at most once; placed input belongs to a live run and
settles; a Stop keeps a routine's prompt; nothing stays running; a machine
call records one result, an op's result reaches at most one tool result,
and every row closes; one routine carries a schedule at a time, no firing
lands after an edit or delete, and each firing happens once; the settle
hook runs once per settle; an ask has one question, answered at most once
and never after it was withdrawn, an answer always reaches a call still
waiting, and a question Blip didn't handle reaches the owner.

### `HubOps.tla`

The operation protocol for one machine and one or two `shell` calls: the
call as a durable tool task, its op row and signal (`Photon.Machines`,
`Machines.Rules`), the Store's commit line, the machine's `NodeChannel`
and mailbox, the websocket both ways, the node's `Connection`, and the
executor with its journal, operation processes and commands.

Faults: websocket drops, hub restarts, Scheduler-only crashes (orphaned
steps), node restarts that keep or kill running commands, the node losing
its data directory, Stops at any point, tool steps that end in an error,
and repeated `op.start` pushes.

Properties: a command runs at most once per call (after data loss, an op
the hub had confirmed never runs again); each call gets exactly one result,
and it is what its own op did; the offline message says "didn't run" only
when the command never ran; no `op.start` for a canceled row; the node
forgets an op only after the hub recorded its result; every call is
answered, a cancel takes effect, and every row closes. Capabilities
(`"ops:2"`) aren't modeled.

### `Executor.tla`

The node side, opened up: the executor's handlers (`op.start`, `op.cancel`,
`op.ack`, checkpoints, reports, `:DOWN`, the start-up scan) as ordered
effects, so it can crash after any prefix of them; the journal; the
`Ops.Shell` processes; and the commands with their process groups,
background children and `exit`, `pid`, `stopped`, `canceled` and
`unstarted` files. The hub is a stand-in that follows the hub rules in
`docs/operations.md`.

Faults: executor crashes inside any handler, operation process crashes,
abrupt node crashes (commands survive), node stops (shells kill their
commands), dropped connections, extra `op.start` pushes, cancels, and
commands that leave background children or never exit.

Properties: a command starts at most once; once the hub has a result,
nothing of the command is running; the result says what happened
(`completed` only for a command that exited on its own, `canceled` only
after a cancel, `failed` only after a fault); every op gets its result, a
cancel ends even a command that would run forever, and every finished
entry is forgotten. `Executor-cancel.cfg` and
`Executor-bug-cancel-before-pid.cfg` let commands run forever
(`SpecUnboundedCommands`), so they check `CancelTakesEffect` rather than
`CallResult`.

## Property tests

| App | File | What it checks |
| --- | --- | --- |
| core | `sse_property_test.exs` | `SSE.parse` gives the same payloads however a stream is cut, and never raises |
| core | `llm_stream_property_test.exs` | an answer streamed in any chunks gives `LLM.stream/3` the same result and events as folding the whole body |
| core | `message_property_test.exs` | `Message.arguments` never raises and decodes objects exactly; text and parts agree; every conversation encodes as Responses input |
| core | `output_property_test.exs` | `Output.bound` gives valid UTF-8 in the documented head/tail/marker shape; `sanitize` only replaces invalid bytes |
| node | `journal_property_test.exs` | a journal entry survives a crash at any point of a write: `read/2` returns the last entry fully written, or none |
| hub | `durable_context_property_test.exs` | `Context.messages` pairs calls and results and sees nothing before the newest reset |
| hub | `durable_schema_property_test.exs` | `Schema.validate` never raises and agrees with an independent reading of its JSON Schema subset |
| hub | `machine_ops_property_test.exs` | op rows under duplicated, stale and foreign snapshots, reconnects, cancels and claims: a row only moves forward, its signal fires exactly when it leaves `open`, no `op.start` for a canceled row, a result is claimed at most once |
| hub | `durable_model_property_test.exs` | model-based test of the harness (submit, steer, follow-up, retried request IDs, abort, full and Scheduler-only restarts): one active run, retried requests submit once, every submission settles, the transcript stays well formed |

All run by default. A property tagged `:known_bug` (none today) is excluded
unless you pass `--include known_bug`.

## Finding IDs

Tests, configs and spec comments cite findings by ID. Durable `F1` to
`F10b` are written up in `specs/tla/Durable.md`; `F3`, `F8`, `F9`, `F11`,
`K1`, `E1`, `K2` and `G1` in `specs/tla/Executor.md`; HubOps `H1` to `H8`
in `specs/tla/HubOps.md`. The rest were found by property tests:

| ID | Bug | Pinned by |
| --- | --- | --- |
| hub-abort-strands-submission | input queued behind a stopped run was never started | hub `boundary/durable_regression_test.exs` |
| hub-function-exported-unloaded | `function_exported?/3` is false for an unloaded module, so an early abort skipped `on_abort` (fixed in `Durable.implements?/3`) | hub `boundary/durable_regression_test.exs`, `property/durable_model_property_test.exs` |
| hub-schema-raises-beyond-subset | boolean subschemas or enums of objects crashed `Schema.validate` | hub `core/durable/schema_test.exs` |
| core-sse-crlf-split | a payload's trailing CR depended on where the stream was cut | core `core/sse_test.exs` |
| core-message-arguments-raises | a call with missing or non-text arguments raised | core `core/message_test.exs` |
| core-negative-retry-after | a negative `Retry-After` made `Process.sleep/1` raise in the caller | core `core/http_error_test.exs`, `boundary/llm_test.exs` |
| node-op-stale-registry | `Registry.lookup/2` listed a just-exited op process, so a resend failed the op | node `boundary/shell_test.exs`, `core/executor/rules_test.exs` |

## How to run

ExUnit, in each app, with Elixir 1.20.4 on OTP 28:

```sh
cd apps/core && mix test
cd apps/node && mix test
cd apps/hub && mix test
```

`mix test test/property` runs only the properties.
`PHOTON_PROPERTY_RUNS=250` raises the run count of the hub's durable-model
and machine-ops properties.

TLC (TLA+ tools 2.19), from `specs/tla`:

```sh
java -XX:+UseParallelGC -cp tla2tools.jar tlc2.TLC \
  -workers auto -deadlock -metadir /tmp/tlc/<Cfg> -config <Cfg>.cfg <Spec>.tla
```

`<Spec>` is `Durable`, `HubOps` or `Executor`, and `<Cfg>` one of its
`.cfg` files. Add `-lncheck final` for configs with `PROPERTIES`.
`-deadlock` is needed because every modeled behaviour ends. A `-bug-*`
config passes when TLC reports the violation its spec's notes name; any
other outcome, including a different violation or a parse error, is a
failure.

## Limits

- Power loss isn't modeled: the journal and the database are fsynced
  before they are acted on, but a reader could see a write before its sync
  finished.
- `Executor.tla` leaves out journal write failures and unreadable entries
  (node rule 8), output, `view_image`, the frame budget and the sweep;
  ExUnit covers them (`executor_test.exs`). Its hub is a stand-in, and
  `HubOps.tla` leaves out executor and operation-process crashes, so no one
  spec has both a hub crash and an executor crash.
- `Durable.tla` reduces the machine to its row and signal and bounds a
  call's rechecks (`MaxRechecks`); `HubOps.tla` models the rest of the
  protocol. It models one schedule, without times, and bounds a routine's
  firings (`MaxFires`). For `ask_blip` it leaves out Blip's reasoning, the
  texts, signal merging, thread state and the activity log.
