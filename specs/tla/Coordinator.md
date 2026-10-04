# Coordinator: TLA+ model of one node session

`Coordinator.tla` models one session's coordinator on a node (the state
machine in `apps/node/lib/photon_node/harness/session.ex` and the server
that runs it, `coordinator.ex`) together with the pieces it depends on: the hub's input outbox and websocket, the session log
(`Store`), the LLM task, the shell operation processes (`ops/shell.ex`),
the OS commands they start, and the faults the system says it survives.
The reference is `docs/unreal-agent-port-spec.md`, sections 6 (coordinator)
and 9 (operations).

The first version of the spec modeled the code as it was and found eleven
real problems and one known upstream gap (K1), each reproduced by a
`Coordinator-bug-*.cfg`. All twelve are fixed in the code, and the spec
now models the fixed code. The bug configs are kept as regression checks
(same constants, the same property plus related ones), and every config
except the witness one is expected to finish with no error.
`docs/verification.md` lists the ExUnit regression test for each finding.

A review of the fixes changed the code in two places this spec touches.
Hub stops now go through the same call as inputs (NS-9 in `NodeSync.md`),
so `HubStop` and `Retried` changed (see "Faults and fairness"). And
`Ops.add/2` no longer reuses an operation process the registry still lists
after it exited, which this spec doesn't model (it has no registry; see
"Below the model" at the end).

A later refactor of the node (see the node section of the refactor log in
`docs/architecture.md`) moved the coordinator's logic out of its GenServer
into a pure module, `PhotonNode.Harness.Session`, without changing what it
does. The code now has the shape this spec always had (see "State and
code mapping"), and the tables below name the new places. The spec itself
didn't change, apart from comments that point at the code, and every
config was re-run afterwards (see "Results").

## How to run

TLC lives at `~/.local/share/tla/tla2tools.jar` (Java 21 at `/usr/bin/java`).
From `specs/tla`:

```sh
java -XX:+UseParallelGC -cp ~/.local/share/tla/tla2tools.jar tlc2.TLC \
  -workers auto -deadlock -metadir /tmp/tlc-Coordinator \
  -config Coordinator.cfg Coordinator.tla
```

Swap `Coordinator.cfg` for any `Coordinator-*.cfg` below; add
`-lncheck final` for configs with `PROPERTIES`. `-deadlock` is needed
because a finished session (everything idle, budgets spent) is a terminal
state on purpose. `Coordinator-witness.cfg` needs `-continue`.

## Results

TLC 2.19 on a shared 12-core machine at load around 38. Every config: no
error. These are the numbers after the review's change to `HubStop` and
`Retried`, with 3 workers while another TLC run shared the machine; the
configs with a stop grew a little (a stop can now move to the next
incarnation), the others are unchanged.

| Config | Scenario | Distinct states | Time |
| --- | --- | --- | --- |
| `Coordinator.cfg` | 1 input, up to 2 calls per response, heartbeat, stop; no faults | 211,272 | 7m39s |
| `Coordinator-inputs.cfg` | 2 inputs, 1 call, stop, duplicate delivery, websocket drop | 70,932 | 3m02s |
| `Coordinator-crash.cfg` | 1 call, stop, 1 coordinator crash anywhere inside any handler | 2,216 | 7s |
| `Coordinator-nodecrash.cfg` | 1 call, stop, 1 abrupt node crash anywhere, then boot and rejoin | 1,990 | 5s |
| `Coordinator-crash2.cfg` | up to 2 calls per response, 1 coordinator crash | 98,259 | 3m20s |
| `Coordinator-nodecrash2.cfg` | up to 2 calls per response, 1 node crash | 50,376 | 1m17s |
| `Coordinator-faults.cfg` | up to 2 calls per response, 1 coordinator crash and 1 node crash; safety only | 1,955,546 | 6m00s |
| `Coordinator-bug-orphan-llm.cfg` | F1: 1 coordinator crash | 368 | 2s |
| `Coordinator-bug-stop-forgotten.cfg` | F2: 1 stop, 1 coordinator crash | 2,216 | 5s |
| `Coordinator-bug-double-exec.cfg` | F3: 1 coordinator crash | 368 | 2s |
| `Coordinator-bug-stop-swallows-input.cfg` | F4: 2 inputs, 1 stop | 5,112 | 9s |
| `Coordinator-bug-idle-stop-loses-input.cfg` | F5: 2 inputs, idle stop | 795 | 2s |
| `Coordinator-bug-crash-loses-input.cfg` | F6: 1 coordinator crash | 368 | 2s |
| `Coordinator-bug-not-resumed.cfg` | F7: 1 node crash | 492 | 3s |
| `Coordinator-bug-cancel-before-pid.cfg` | F8: 1 stop, commands may run forever | 185 | 2s |
| `Coordinator-bug-op-crash.cfg` | F9: 1 stop, 1 op process crash | 373 | 4s |
| `Coordinator-bug-tool-vanish.cfg` | F10: 2 inputs, the tool goes away | 1,072 | 3s |
| `Coordinator-bug-bg-reattach.cfg` | F11: 1 node crash, background children | 559 | 3s |
| `Coordinator-known-orphan-command.cfg` | K1: 1 node crash | 492 | 2s |

After the node refactor (2026-10-03) every config was re-run with 4
workers on the same loaded machine. The spec had changed only in comments.
Each config finished with no error and the same number of distinct states
as in the table above; `Coordinator.cfg` took 4m13s and
`Coordinator-faults.cfg` 4m23s. `Coordinator-witness.cfg` violated all six
witness invariants again before TLC threw its exception.

Each config file lists what it checks. Compared with the first version,
the fault configs now also check the properties their fault used to break:
`AtMostOneLLM`, `IdleNoLLM`, `AtMostOnceExec`, `StopHonored`,
`InputDuringStopAnswered`, `InputAnswered` and, after a node crash,
`IdlePhysical`. The state spaces are smaller than before because the
orphaned LLM tasks, the double command starts and the lost mailboxes each
added states the code no longer reaches.

`Coordinator-witness.cfg` (run with `-continue`; it prints a trace per
violation) still violates all six witness invariants, so the model
reaches the interesting cases. In the review's runs TLC 2.19 itself threw
an `ArrayIndexOutOfBoundsException` after about three minutes of printing
traces (with 4 workers and with 1), having hit all six thousands of times;
that is a TLC problem with `-continue`, not the spec. The cases: a
placeholder sent and a real result later, a grace period still waiting
after one of two calls finished, heartbeats, steering, a canceled command
before `stopped`, and an error status forcing a turn.

### Properties

Safety (invariants and action properties):

- `AtMostOneLLM`: never two LLM requests running for the session. Holds
  under crashes (the request task is linked to the coordinator).
- `OneResultPerCall`: the log has at most one terminal `tool_call_status`
  per call. Holds, a tool that goes away included.
- `ReplayMatches`: whenever a coordinator runs, replaying its log
  reproduces its live state: `available`, `delivered`, `turn_inputs`, the
  current turn, `busy`, the calls and their statuses, the operation map, the
  inbox's seen IDs, and the placeholder and real results in the Context.
  Holds in every config that checks it, crashes included. Every live
  mutation of that state goes through `apply_item/2` right after the
  matching `persist/3`, and `handle_stop/1` sets `delivered` in step with
  the `stopped` record that replay reads.
- `ContextSound`: a call never gets two real results; no turn starts with
  nothing pending; the placeholder of a call in the current grace set is
  never committed while grace runs. Holds.
- `HeartbeatArming`: the heartbeat is armed exactly when the coordinator
  waits only for tool calls. Holds.
- `AtMostOnceExec`: one OS command start per operation. Holds under
  coordinator and node crashes.
- `StopQuiet`: after a `stopped` record, no `turn` until a new external
  input. Holds.
- `StopHonored`: once a hard stop is logged, no `turn` until `stopped`.
  Holds under crashes.
- `InputDuringStopAnswered`: an external input that arrives while a hard
  stop is in progress is not folded into that stop. Holds.
- `IdleLogSound`: an `idle` record is written only when the log shows no
  pending input, no unfinished call, and no live operation. Holds.
- `IdleNoLLM`: no LLM task of the session is alive when `idle` is written.
  Holds.
- `IdlePhysical`: no op process or OS command of the session is alive when
  `idle` is written. Holds after a node crash.

Liveness:

- `InputAnswered`: every external input the hub sends is eventually
  followed by a turn that starts after it and gets a `model_response`,
  unless a `stopped` record follows it. Holds under coordinator and node
  crashes, the idle-stop race and a stop.
- `CallResult`: every tool call in a `model_response` eventually gets a
  terminal result in the log. Holds given that commands exit, with op
  process crashes and background children.
- `RunningSettles`: whenever the last state record is `running`, a later
  `idle` or `stopped` follows. Holds when commands exit (it can't hold for
  a command that runs forever with no stop).
- `StopCompletes`: a hard stop the running coordinator has accepted is
  eventually followed by `stopped`, unless a crash forgets the in-memory
  stop first (it is then re-armed from the log). Holds, also when
  commands may run forever.

## The findings, and how they were fixed

Each entry gives the TLC trace from the first version (the code before the
fixes), the cause, and the fix now in the code. Line numbers are from that
snapshot, in `coordinator.ex` unless another file is named.

### 1. A crash after spawning the LLM task orphans it, and the restart starts a second request

Trace (`bug-orphan-llm`): input 1 arrives. Its handler persists the input
and `turn 1`, spawns LLM task 1 (`request_model_response/1`, 513-539), then
crashes on the next append, the `running` record (`record_run_state/1`,
757; `Store.append/3` matches `:ok` on write and datasync). `terminate/2`
(248-254) gets the state from before the callback, where `llm` is nil, so
it kills nothing. Task 1 was started with `async_nolink` (532), so it keeps
streaming. The supervisor restarts the coordinator, replay finds `turn 1`
without a response, `pending > 0`, and `handle_continue` starts turn 2.
Two requests run at once; task 1's live events still reach the hub
(`Connection.live`) and it spends tokens until it finishes.

Real, low severity: it takes a store write failure right after a turn
starts.

Fixed: the request task is started with `Task.Supervisor.async`, linked
to the coordinator. The coordinator traps exits, so a task crash still
arrives as a message, but when the coordinator dies the task dies with it,
whatever state the crash happened in.

### 2. A crash during a hard stop forgets the stop

Trace (`bug-stop-forgotten`): input 1 and a hard stop are in the mailbox.
The handler persists both, then crashes before `stopped` is appended
(`handle_stop/1`, 735). Replay applies the `hard` input as a no-op
(`apply_input/2` catch-all, 433); only `handle_input/2` calls
`accept_stop/1` (303-304). The restarted coordinator sees input 1 pending
and starts a turn. The same happens for a crash at any point while a stop
waits for canceled operations to settle.

Real, low to medium. Upstream also skips stop controls on resume (port
spec 6.10), but there a stop ended the runner process. The hub's stop is
not retried: `Harness.stop/1` only sends if a coordinator is running
(harness.ex:39-52) and `NodeSessions.stop/1` stores nothing. (The review
made `Harness.stop/1` a retried call; see NS-9 in `NodeSync.md`.)

Fixed: `apply_input/2` arms the stop for a hard control input and a
`stopped` (or `idle`) record clears it, so replay re-arms a pending stop
and `handle_continue` finishes it. Operations dispatched during that
replay ask before starting their command (finding 3) and are told to
cancel.

### 3. A shell command can run twice for one operation

Trace (`bug-double-exec`): a response with one Bash call is persisted and
its operation dispatched. The coordinator then crashes in the same handler.
The shell op starts anyway: `prepare/1` sends the `awaiting`/`process`
checkpoint and immediately spawns the command (ops/shell.ex:100-107). The
checkpoint and every later one go to `Coordinator.notify/2`, which drops
them while no coordinator is registered (74-77). The command finishes, the
op process exits, and the restarted coordinator still has the op as
`ready` in its log. `Ops.add/2` finds no process and starts a new one from
`ready`, which runs the command again. With `MaxNodeCrash = 1` the same
happens after a node crash that lands between the spawn and the coordinator
persisting the checkpoint, and then the first copy may still be running.

Real, medium for non-idempotent commands, narrow window. Upstream shares
the race (the manager starts primitives without waiting for the checkpoint
to be saved), but its recovery rule ("phase process without a pgid: outcome
unknown") shows the intent is at most once.

Fixed: `Ops.Shell.prepare/1` asks the coordinator to persist the
`process` checkpoint with a call (`Coordinator.checkpoint/2`) and spawns
only on `:ok`. With no coordinator, or an unknown or finished operation,
it stops without starting anything; during a hard stop it cancels. The
model's `OpInit`/`OpSpawn`/`OpCancelAck` and the `ack` effect follow this.

### 4. An input sent during a stop is swallowed by it

Trace (`bug-stop-swallows-input`): the mailbox holds external input 1, a
hard stop, and external input 2. One slurp logs all three. `decide/1` runs
`handle_stop/1`, which records `stopped` and sets `delivered` to
`available` (736), which now includes input 2. Input 2 is never answered,
and the hub settles it as "Stopped before finishing."
(node_sessions.ex:222-231). The window also covers the time a stop waits
for commands to die: `kill_group/1` gives SIGTERM five seconds before
SIGKILL (ops/shell.ex:407-427).

Real, medium for the user: a message sent right after pressing stop is
dropped. Upstream leaves such inputs pending for the next run.

Fixed without changing the log format: external input that arrives while
a hard stop is pending is held in memory (`handle_input/3`) and persisted
once `stopped` is written (`resume_deferred/1`), so it gets its own turn
and the hub settles it with that turn's answer. The delivery call that
brought it is answered then.

### 5. An input queued behind `:idle_stop` is lost

Trace (`bug-idle-stop-loses-input`): after input 1 is answered the
coordinator is idle and its idle timer fires (`arm_idle_stop/1`, 811-817).
Input 2 arrives: `Harness.deliver/3` gets the running pid from
`ensure_started` and sends (harness.ex:28-37), behind `:idle_stop` in the
mailbox. `handle_info(:idle_stop)` checks only `idle?/1` and stops with
reason `:normal` (241-242); the coordinator is `restart: :transient`, so
nothing restarts it, and input 2 dies with the mailbox. The hub keeps input
2 as `queued` but resends queued inputs only when the node rejoins
(node_channel.ex:81-84). While the websocket stays up, input 2 is never
answered.

Real, narrow (the input has to land within the moment the timer message is
handled, or in the gap before the registry drops the dead pid).

Fixed: `Harness.deliver/3` is a call that returns once the input is
persisted. A call to a coordinator that exits gets an exit; `deliver`
waits for that process to go and retries with a new coordinator (up to
five attempts).

### 6. Inputs in a crashing coordinator's mailbox are lost

Trace (`bug-crash-loses-input`): input 1 is in the mailbox when the
coordinator crashes, before it is persisted. The supervisor restarts the
coordinator with an empty mailbox. As in finding 5, the hub resends only
on rejoin, so input 1 waits until the websocket happens to drop.

Real, low (needs a crash). Same root cause as finding 5: the mailbox is
not durable and the hub assumes a connected node accepts what it is sent.

Fixed by the same synchronous delivery with retry: the retried call
reaches the restarted coordinator, which dedupes it if the crash happened
after the input was persisted.

### 7. A node crash before `running` leaves an accepted input unanswered

Trace (`bug-not-resumed`): input 1's handler persists the input; the node
dies before `turn` and `running` are appended (`decide/1` persists the
turn, then `record_run_state/1`). The hub already has the input record, so
it marks the input accepted and will not resend it. On boot,
`Harness.resume_all/0` starts only sessions whose last state record is
`running` (harness.ex:67-74, 151-160); this log has none (or `idle` from
an earlier run). The input sits unanswered until another input wakes the
session.

Real, narrow (two fsyncs wide).

Fixed: `Harness.working?/1` is also true when an external input follows
the last `model_response` or `stopped` record.

### 8. A cancel that beats the `pid` line does not stop the command

Trace (`bug-cancel-before-pid`, commands may run forever): a response
starts a Bash command and a hard stop arrives in the same slurp.
`handle_stop/1` sends `:cancel` (730). The shell op has opened the port but
not yet read the wrapper's `pid` line, so
`handle_info(:cancel, state)` calls `kill_group(nil)`, a no-op, and only
sets `canceled` (ops/shell.ex:219-222, 413). The `pid` handler that runs
next stores the pgid and never looks at `canceled` (158-163). The command
runs until it exits by itself. For a server or `sleep 1e9` that is never:
the session stays in "stopping", starts no turns, and answers no new
input.

Real, medium (narrow trigger, bad outcome).

Fixed: the `pid` handler kills the group at once if `canceled` is set.

### 9. A crashed op process is never noticed

Trace (`bug-op-crash`): a call's op process crashes before it finishes.
Op processes are `restart: :temporary` (ops/shell.ex:22) and the
coordinator does not monitor them, so the operation stays non-terminal in
its state forever. The call never gets a result, the session never leaves
`running`, heartbeats fire every ten minutes for good, and a hard stop
never completes because `Ops.cancel/1` finds no process (ops.ex:48-55).
Only a coordinator restart recovers it, and the idle stop that would cause
one never comes. Shell has several crash points that are not handled:
`{:ok, data} = read_at(...)` in `stream_live/1` and `bounded_file/2`
(ops/shell.ex:361, 365-366, 453) and `System.cmd` in `kill_group/1`.

Real, medium.

Fixed: `Ops.add/2` returns the operation's pid and the coordinator
monitors it. A `:DOWN` for an operation that isn't terminal fails it
("the operation process exited: ..."), except a clean exit, which means
the operation stopped before starting its work (its checkpoint wasn't
confirmed); that one is started again, once.

### 10. A call whose tool no longer resolves wedges the session on replay

Trace (`bug-tool-vanish`): a session runs a tool call to completion and
goes idle, and the coordinator stops. The tool then stops resolving, and a
new input restarts the coordinator. Replay applies the call's terminal
status, but `add_tool_result/2` returns the state unchanged when
`Tools.resolve/2` is nil and the status is not error-only (447-453). The
call stays in `calls`. `handle_continue` reconciles it and appends a second
terminal `tool_call_status`, and every later slurp appends another
(`reconcile/1`, 652-671). The session records `running` and never goes
idle; the heartbeat keeps waking the model about a call that finished long
ago.

How the tool goes away in practice: SkillUse is enabled only when
`<workspace>/.harness/skills/*/SKILL.md` exists when the coordinator
starts (coordinator.ex:109, 123; tools.ex:22-25). Deleting that folder,
which the agent itself can do with Bash, wedges every session that ever
used SkillUse the next time it starts. A `settings` input that disallows a
tool while one of its calls runs does the same live.

Real, medium. Upstream fails the restore with an error instead (port spec
6.10, 6.11).

Fixed: `add_tool_result/2` finishes such a call once its operations are
terminal, with a generic result ("The X tool is no longer available, so
its result can't be shown. Its work ended: ..."), and shows the
placeholder while they run.

### 11. A reattached shell waits for background children

Trace (`bug-bg-reattach`): the node crashes while a command runs with its
pgid persisted. After boot the shell op reattaches and polls
(ops/shell.ex:251-254). The command exits and the wrapper writes the exit
file, but a background child stays in the group. `poll_recovered/1` checks
`group_alive?/1` before the exit file (264-271), so it keeps polling while
the child lives. In the normal path the group is killed when the wrapper
exits (177), as the Bash tool description promises. `recover/1` checks the
exit file first (243-249), so only polling has the wrong order.

Real, low (needs a node restart during such a command).

Fixed: `poll_recovered/1` checks the exit file first, then kills the
group and finishes.

### K1. Known gap: recovery could leave a command running after `idle`

Trace (`known-orphan-command`): the node crashes after the `process`
checkpoint without a pgid is persisted but before the `pid` checkpoint is.
Recovery fails the op ("outcome is unknown because process start was not
recorded", ops/shell.ex:240-241). Without a pgid nothing can kill the
command, so the session records `idle` while it still runs. This matches
upstream (port spec 9.3 and 12.8), so it isn't a port regression.

Fixed anyway, since it was cheap: the wrapper writes the command's pid to
`pid` next to `exit` as it starts it, and recovery reads it when the
snapshot has no pgid, then waits for (or kills) the command as usual. The
model writes the pid file with the spawn (`pidf`).

### Observations from reading the code (not traced)

- `handle_continue/2` dispatches without reconciling afterwards (now
  `Session.resume/1` then `decide/1`), and the heartbeat handler does not
  slurp or reconcile (`Session.heartbeat_fired/1` then `decide/1`). If
  `Ops.add/2` failed at startup, the failed operation's call would wait for
  the next heartbeat, and forever with heartbeats off. `Ops.add/2` only
  fails for unsupported types, which logs cannot contain, so this is
  latent. The core test "an operation that can't be started fails" pins
  this behavior.
- After a coordinator-only crash, a shell op whose `pid` checkpoint was
  dropped while the coordinator was down, and which finished in that gap,
  was recovered as "outcome unknown" (failed) although it completed. The
  pid file (K1's fix) covers this too: recovery finds the group, then the
  exit file, and finishes it normally.
- In `poll_recovered/1`, the group can be gone a moment before the wrapper
  writes the exit file, which reports "interrupted" for a command that
  completed. The model writes the exit file atomically with the exit, so it
  does not show this.

## What is modeled

### State and code mapping

| Model | Code |
| --- | --- |
| `S` (record) | the `%Session{}` struct (`Session.new/3`); the coordinator process adds only the open log, the request task, timer references and operation monitors |
| `S.available/delivered/turnInputs` | `available`, `delivered`, `turn_inputs` |
| `S.calls`, `S.cst`, `S.ops` | `calls` (status nil/ok/error), `operations` |
| `S.callModel`, `S.llm`, `S.grace`, `S.hb`, `S.stop`, `S.busy` | same names |
| `S.ph`, `S.real` | `Context` tool results per call, staged or committed (`Context.add_tool_result/5`, `commit/1`) |
| `S.seen` | `Inbox` seen set, seeded from logged input IDs (`Session.replay/2`) |
| `S.idleMsg` | an `:idle_stop` message in the mailbox |
| `S.deferred` | external inputs held while a hard stop finishes |
| `log` | the session log; records `input`, `turn`, `resp` (model_response), `status` (tool_call_status), `op` (operation), `state` |
| `inq`, `opq` | the coordinator mailbox: deliveries (`{:deliver, config, input}` calls from `Coordinator.deliver/3`, or `{:input, _}` messages) and operation snapshots (`{:op_update, _}` messages, and `checkpoint/2` calls) |
| `tasks` | LLM tasks under `PhotonNode.Harness.TaskSupervisor` (`ModelRequest.start/3`) |
| `op[c]` | the shell op process for call `c` (`ops/shell.ex`); `proc` "await" (waiting for its checkpoint call), "go", "cancelling", "spawning", "running", "polling" |
| `os[c]` | the command, its process group (incl. background children), its `exit` file, its `pid` file (`pidf`) |
| `hubSent`, `connected` | the hub outbox (`NodeSessions.Input`) and the websocket |

### Actions

| Action | Code |
| --- | --- |
| `ContinueStep` | `Coordinator.handle_continue(:start)`: `Session.resume/1` (schedule, reconcile, dispatch), then `Session.decide/1` |
| `InputStep` | `Coordinator.handle_call({:deliver, ...})` (`Session.deliver/4`) + the coordinator's `slurp/1` + `Session.decide/1` |
| `OpStep` | `Coordinator.handle_info({:op_update, _})` and `handle_call({:op_update, _})` (checkpoints), `Session.op_update/3` (`handle_op_update/3`) |
| `LLMStep` | `Coordinator.handle_info({ref, result})` / `{:DOWN, ...}`, `Session.model_response/2` (`process_model_response/3`) |
| `GraceStep` | `Coordinator.handle_info({:grace, ref})`, `Session.grace_expired/1` |
| `HBStep` | `Coordinator.handle_info({:heartbeat, ref})`, `Session.heartbeat_fired/1` (`post_heartbeat/1`) |
| `IdleFire`, `IdleStop` | `Session.arm_idle_stop/1` (the `{:arm_idle_stop, ms}` effect), `Coordinator.handle_info(:idle_stop)` (asks `Session.idle?/1`) |
| `CrashIn`, `NodeCrashIn` | a crash after any prefix of a handler's effects; the linked LLM task dies; shells waiting on a checkpoint call stop; pending deliveries are retried (`Retried`) |
| `SupervisorRestart`, `NodeBoot` | `restart: :transient`; `Harness.resume_all/0`, `Session.working?/1` |
| `HubSend`, `HubDup`, `HubStop`, `Reconnect` | `NodeSessions.send_input/3`, `resend_queued/1`, `stop/1`; `Harness.deliver/3`, `Harness.stop/1` (both calls answered once the input is in the log) |
| `OpInit` | `Shell.handle_continue(:start)`: `prepare/1` (asks `Coordinator.checkpoint/2`), `recover/1` (pgid from the snapshot or the pid file), `finish/2` |
| `OpSpawn`, `OpCancelAck` | the checkpoint call's reply: `:ok` starts the command, `:cancel` cancels without starting it |
| `PidLine`, `PortExit`, `OpCancel`, `OpResend`, `Poll` | `Ops.Shell`: the `pid` line handler, `{:exit_status, _}` (`exited/2`, after `kill_group/3`), `:cancel`, `:resend`, `:poll` (`poll_recovered/1`). Killing a group no longer blocks the shell process, but messages that arrive meanwhile are postponed, so each of these steps stays atomic as modeled |
| `CmdExit`, `BgExit` | the command (and any background child) exiting; the wrapper writes `exit` |
| `OpCrash` | an op process crash; `terminate/2` kills the group if it knows the pgid; the coordinator's monitor turns the `:DOWN` into a `failed` update (`Session.op_down/3`) |

The coordinator's functions are written as pure operators over `S`
(`ApplyItem`, `HandleInput`, `Slurp`, `Schedule`, `Reconcile`, `Decide`,
`HandleStop`, ...), one per Elixir function, in the same order. Each
handler collects its side effects in order (`log` appends, LLM spawn and
kill, `Ops.add`, `Ops.cancel`). A normal step applies all of them; a crash
step applies any prefix and then kills the process. `Store.append/3` syncs
each record before returning, so a crash leaves exactly a prefix of a
handler's records in the log. Replay (`Session.replay/2`) is the same
`ApplyItem` folded over the log.

The code has the same shape. `PhotonNode.Harness.Session` is pure
functions over a `%Session{}` token that collects effects in order
(`{:persist, kind, data}`, `{:request, turn_id, request}`,
`:cancel_request`, `{:dispatch, op}`, `{:cancel_op, op_id}`, replies,
warnings, and arming or cancelling the grace, heartbeat and idle timers).
The private functions keep the names the operators model. `Coordinator`
runs a handler as steps (the event, the mailbox drain, `decide/1`) and
runs each step's effects before the next step starts. One thing the model
leaves out: if `Ops.add/2` fails, the coordinator hands the failure back
(`Session.dispatch_failed/3`) and runs the effects that come back before
the rest. The model's `Ops.add` never fails, and for operation types a log
can hold, the code's doesn't either. `test/property/session_property_test.exs`
checks `ReplayMatches` and the ordering rules on the pure core, with no
processes.

### Faults and fairness

Deliveries are calls (`Harness.deliver/3` for inputs, `Harness.stop/1`
for hard stops): when a coordinator dies with deliveries in its mailbox
(or held during a stop), the callers retry with the next incarnation,
which the model writes as those messages moving to the new coordinator's
mailbox (`Retried` in `CrashIn` and `IdleStop`). A hub stop for a session
with no coordinator running starts one if the log says the session is
working (`WorkingLog`, the same test as `NodeBoot`); otherwise it is
dropped, since there is nothing to stop. Until the review, hard stops were
plain messages, lost with the mailbox.

In the code, a shell whose checkpoint call fails stops without starting
its command, and the restarted coordinator dispatches it again from what
the log says. If the new coordinator's dispatch reaches the old process
before it exits, the coordinator's monitor sees a clean exit of a live
operation and dispatches it once more. The model kills the waiting shell
atomically with the crash, so it only takes the first path.

Faults, each with a budget in the config: coordinator crash at any point
in any handler (the supervisor restarts it); abrupt node crash at any point
(all BEAM processes die, OS commands survive, boot runs `resume_all`, the
socket rejoins and the hub resends queued inputs); op process crash;
websocket drop; duplicate input delivery; the tool disappearing between
incarnations. Messages are not lost or reordered between two live
processes, as Erlang guarantees; they are lost when the receiver dies, and
`Coordinator.report_op/2` drops them while no coordinator runs.

Fairness (weak, matching what the code guarantees): every queued message
is eventually handled; the LLM request eventually returns (the adapter
retries, then fails, and a crashed task becomes `{:DOWN, ...}`); armed
timers fire; op processes make progress; the wrapper prints its pid; the
supervisor restarts a crashed coordinator; a crashed node boots and
rejoins. `Spec` adds that commands eventually exit; `SpecUnboundedCommands`
drops that (servers, long sleeps). Nothing is fair about the user, the
model's choices, or faults.

### Abstractions

- Inputs: external inputs and hard stops come from the hub; heartbeats
  from the timer. Settings inputs are not modeled: the hub sends each
  session's fixed config, so a delivery's config never records a change. The
  tool-vanish fault stands in for the settings change that matters.
- The model's answer is any number of tool calls up to the budget, each
  valid (one operation) or invalid (error status). A failed response (no
  message) affects the coordinator exactly like a text answer, so it is
  not a separate choice. Call kinds are generated sorted (valid first).
- Operations: shell only. Every translator makes one operation per call,
  and view_image and skill_use finish inside their `handle_continue`, so
  they are a special case of shell. The operation ID is the call ID; a
  call translated again after a crash gets new IDs in the code, which is
  equivalent because the old operation never left the coordinator.
- Time is not modeled. Grace, heartbeat and idle timers fire at any point
  while armed. Stale grace and heartbeat messages hit the ref check or
  the catch-all (233, 237, 246) and do nothing, so the model drops them
  when the timer is re-armed or cleared. `:idle_stop` has no ref, so it is
  modeled as a message that is ahead of any input arriving after it.
- The slurp drains every queued input, then every queued op update. Op
  updates of different operations are drained in operation order, not
  arrival order; that only reorders `operation` records, which replay
  treats independently.
- The Context is tracked per call as placeholder and real result, each
  staged or committed. User messages and the message order inside it are
  not modeled.
- Node shutdown is abrupt. A graceful stop runs the shell op's
  `terminate/2`, which kills commands that recovery then reports as
  completed with exit code 143; that is not modeled.

### Violations that were modeling artifacts

Four violations along the way came from the model, not the code. I fixed
each one and re-ran.

- The first `IdleFire` let the idle timer fire while the input that had
  just started the coordinator was still in its mailbox. In the code that
  timer takes ten minutes, so the input is always handled first. The timer
  message may now only be enqueued when no input is waiting, and it is
  handled before inputs that arrive after it.
- `IdleSound` failed on the first response because the finished LLM task
  stayed in `tasks`. The response handler now removes it.
- Under coordinator crashes, `IdleSound` failed because of the orphaned
  task from finding 1. I split it into `IdleLogSound` (holds) and
  `IdleNoLLM` (fails only through finding 1).
- `StopCompletes` first failed under crashes because the crash that forgets
  a stop (finding 2) can happen in the same step that logs it, before the
  crash counter could "allow" it. The property now starts from a stop the
  live coordinator holds in memory.

### Below the model

`Registry.lookup/2` returns a registered process until the registry has
handled its exit, so for a moment after an operation process exits it is
still listed. `Ops.add/2` used to send such a process `:resend` and hand
it to the coordinator, whose monitor then reported `:noproc`, which
`op_down/3` took for a crash: the operation failed ("the operation process
exited: no process") although its command never ran. It happens when a
coordinator crashes while a shell waits on its checkpoint call, or on the
re-dispatch after a clean exit. The model has no registry (an operation's
process is `op[c]`, gone the moment it exits), so this was found by review
and pinned by ExUnit tests. Fixed: `Ops.add/2` starts a new process when
the listed one isn't alive, and `op_down/3` treats `:noproc` like a clean
exit (dispatched again, once).

### TLC note

TLC evaluates operator arguments and LET definitions lazily and does not
cache them while it checks invariants, ENABLED, or temporal formulas. The
coordinator is a long chain of state-passing operators, so the first
version took minutes for a few dozen states. Every operator that reads its
state argument more than once now binds it first with
`Strict(x, F) == CHOOSE r \in {F(v) : v \in {x}} : TRUE`, which brings
liveness checking back to normal speed.
