# Step 1: machine tools on the hub

Plan for build step 1 of `docs/projects-and-blip.md`. Nodes become
executors. Blip gets `shell` and `view_image` on any machine, and these
replace `run_on_node` and node sessions.

The work ships as two pull requests:

- PR A adds the new operation protocol, the node's executor and Blip's
  machine tools, alongside today's node sessions. Both paths work at once.
- PR B deletes node sessions, the model relay, the node's agent loop, their
  specs and their UI, and leaves the app coherent without them.

Every section below is meant to be read on its own: an agent handed one task
should read section 1, the section its task points to, and the task itself.
Rule numbers refer to `docs/otp-design-guide.md`; the short version is
`docs/plans/otp-brief.md`. Paths are relative to the repo root.

Nothing here keeps old data. Tables, the hub-node wire protocol and node
installs are replaced. Photon has one user.

## 1. Goal and scope

After this step:

- Blip runs shell commands and looks at images on any machine itself, with a
  `machine` argument on each call. "Is Codex installed on mm1?" is one
  `shell` call, answered in the same turn.
- A node is an executor. The hub sends it an operation, the node runs it and
  reports snapshots until it finishes, and the hub records the result. Nodes
  no longer run agents, keep session logs or call models.
- The hub's own computer is a machine like any other, reached through the
  node that already runs inside the hub's VM (`node_id: "local"`).
- A call on an offline machine waits durably, up to 10 minutes of the
  machine being offline, then fails with a plain message the model can act
  on.
- Blip's transcript shows each machine call with the machine's name, streams
  a running command's output, and shows images that `view_image` returns.

Out of scope, for later steps:

- Projects, threads, the `"thread"` profile and per-project working
  directories (step 2). Operation arguments carry a `directory` field now so
  step 2 can fill it, but in step 1 it is always null and commands run in the
  node's workspace.
- Skills on the hub (step 3). The node's skills are deleted in PR B and not
  replaced in this step.
- Schedules in projects (step 3), `ask_blip`, the home page and the activity
  log (step 4), ambient mode (step 5).
- The sidebar's project grouping and removing the "+" next to Machines
  (step 2's sidebar work). PR B only removes what showed node sessions.
- Approvals. Commands run without asking, as node sessions do today.
- A timeout on shell commands. Node sessions had none; a long command holds
  Blip's call until it finishes or the user presses Stop.

## 2. The operation protocol

### 2.1 Terms

- Operation (op): one unit of work on one machine. Kinds are `shell` and
  `view_image`.
- Op ID: `op_<suffix>`, minted by the hub from the durable tool task's ID
  `t_<suffix>`. One tool call, one op, one ID, however often the call reruns.
- Snapshot: the full state of an op, the existing operation map
  `%{"id", "type", "version", "status", "max_output_length", "state"}`.
  Statuses are `ready`, `awaiting`, `canceling`, and the terminal
  `completed`, `failed`, `canceled`. A terminal snapshot is the op's result.
- Op row: the hub's durable record of an op (`machine_ops`, section 4.3).
- Journal: the node's durable record of an op, `<data_dir>/ops/<op_id>/op.json`,
  next to the shell's `out`, `err`, `pid` and `exit` files.

### 2.2 Messages

All messages travel on the existing channel `"node:<node_id>"`, with the
existing socket authentication (`PhotonWeb.NodeSocket`, node keys). Payloads
are string-keyed JSON maps, built and parsed in one place,
`PhotonCore.Operation.Wire` (section 4.1). Both sides ignore unknown events
and unknown fields (rule 75).

Hub to node:

| Event | Fields | Meaning |
|---|---|---|
| `op.start` | `id`, `kind`, `args`, `known` | Run this op, or, if the node already has it, send its latest snapshot (and resume it if nothing runs it). `known` is true once the hub has seen any snapshot for the op. Built by the machine's channel from the op row as it is at the moment of the push (rule 2). Sent again once a minute while the call waits on an online machine (rule 11). |
| `op.cancel` | `id` | Stop this op if it is running, and never start it. Final: the node remembers it until `op.ack` (node rule 7). |
| `op.ack` | `id` | The hub has durably recorded this op's terminal result. The node may forget it. |

`args` by kind:

- `shell`: `command` (string, no NUL byte, at most 100,000 bytes),
  `directory` (string or null; null means the node's workspace),
  `max_output_length` (integer, 1 to 1,000,000). The command is passed to
  the shell as one argument, and Linux refuses a single argument over
  128 KB (`MAX_ARG_STRLEN`), so a longer one couldn't run anyway; the cap
  also keeps every snapshot, which carries the command, well under the
  frame limit (node rule 9).
- `view_image`: `path` (string, not blank, no NUL byte; relative paths are
  resolved against `directory`), `directory` (string or null),
  `max_size` (integer, base64 bytes, 4,999,000 today)

Node to hub:

| Event | Fields | Meaning |
|---|---|---|
| `op.snapshot` | `op` (a snapshot) | The op's latest state. Sent at every checkpoint, after every `op.start` for a known op, for every journaled op after each join, and as the answer to `op.cancel` or `op.start` for ops the node can't find (below). A terminal snapshot is the finish message. |
| `op.output` | `id`, `stream` (`out` or `err`), `text` | New command output, sampled once a second, at most 64 KB per stream per sample. Never stored. |

Join: the join parameters stay as today (`hostname`, `platform`,
`workspace`, `version`, `capabilities`). A node that speaks this protocol
adds `"ops:1"` to `capabilities`. In PR A the join reply still carries the
session `sync` map; in PR B it is `%{}`. After a join each side sends what
it holds (section 2.4).

Kinds a node doesn't support come back as a `failed` snapshot saying so.

### 2.3 Rules

On the hub:

1. The op ID is derived from the tool task ID (`t_<suffix>` becomes
   `op_<suffix>`), a pure function of an argument (rule 29). A hub restart
   that reruns the tool's `execute/2` inserts nothing new (the row insert is
   `on_conflict: :nothing`) and asks for the same op to be pushed again.
2. The op row is committed before `op.start` is sent. `op.start` goes out at
   once if the machine is online, and again on every join while the row is
   open and not canceled. Only the machine's channel builds `op.start`, from
   the row as it is when the channel pushes it: `Machines.start/1` commits
   the row and then asks the channel to push that op by sending it
   `{:push_op, op_id}` (in PR A through `Photon.Nodes.push_op/2`, in PR B
   `Photon.Machines.push_op/2`; never through `command/3`), and the channel
   calls `Machines.push_for/2` (its machine and the op ID), which returns `op.start` for an open row of that machine
   without `cancel` (with `known` from the row) and nothing for any other
   row. A join does the same for every open row. These reads go through
   `Durable.commit/1` like the writes, so they wait for a commit in
   progress, and the same commit sets `pushed` on every row it returns an
   `op.start` for (rule 7 needs it). The channel drops a
   `{:command, "op.start", _}` message with a log line, so nothing else can
   put an `op.start` on the wire. (Why: an `op.start` decided before the
   result was recorded and pushed after the `op.ack` reaches a node that
   has just forgotten the op, and it runs again; and a join that reads around a commit in progress
   can miss the `cancel` that commit sets. `HubOps-bug-stale-start.cfg` and
   `HubOps-bug-unserialized-read.cfg` show both.)
3. The first snapshot for an op sets `confirmed` on its row. From then on
   `op.start` carries `known: true`.
4. A terminal snapshot for an open row is recorded in one Store commit: the
   row becomes `finished` (or `closed` if it was canceled, see rule 7) with
   the snapshot stored and `confirmed` set, and the signal `"op:" <> id`
   fires. `op.ack` is sent only after that commit returns.
5. A terminal snapshot for a row that is already `finished` or `closed` gets
   another `op.ack` and changes nothing. A non-terminal one gets `op.cancel`.
6. A snapshot for an op ID the hub has no row for gets `op.ack` if terminal
   and `op.cancel` if not. A snapshot for a row that belongs to another
   machine is ignored and logged.
7. A cancel (user Stop, tool failure, an error result, or the offline
   limit) sets `cancel` on an open row in the same commit that ends the
   tool call, and sends `op.cancel` if the machine's channel is registered
   at that moment, read inside the commit. `cancel_tx` and `abandon_tx`
   both do this. The send happens inside the commit, so the node may get it
   even if the commit then rolls back; node rule 7 makes that safe. If the
   row is already `finished` (the result came in but the call ended another
   way), `cancel_tx` marks it `closed` and clears its snapshot instead, so
   no row keeps a result nobody will claim, and `abandon_tx` claims it and
   returns the real result. Joins resend `op.cancel` for every open row
   with `cancel` set, and never send `op.start` for those rows. The offline
   message is chosen inside the same commit from the row as it is then: "the
   command didn't run" only when the row was never `pushed` and never
   `confirmed`. (Why: `resume/2` reads that the machine is offline before
   its commit. If the node joins in between, the join pushes `op.start`,
   and an abandon that only set `cancel` would leave the command running
   with its call over until the next join. And `confirmed` alone can't say
   a command didn't run: the node may have run it and lost the connection
   before any snapshot arrived. `HubOps-bug-abandon-silent.cfg` and
   `HubOps-bug-offline-confirmed.cfg`.)
8. When the tool records its result, the same commit marks the row `closed`
   and clears the stored snapshot, so a large image isn't kept twice.
9. `Machines.start/1` inserts the row only if, in the same commit, the tool
   task is unfinished and not marked for abort. A step left running by a
   Scheduler-only crash is never stopped, and its later commits are fenced,
   but this commit is the Machines context's own. Without the check it can
   insert a row after Stop ended the call, and that op then runs with
   nothing to cancel it (`HubOps-bug-unfenced-insert.cfg`).
10. Every way a call ends closes or cancels its row in the commit that
    records the result: a claim (rule 8), Stop, a failed task or the
    offline limit (rule 7), and also an error. `Call` returns every error
    result it makes after deriving the op ID as `{:commit, fn tx ->
    Machines.cancel_tx(tx, op_id); error end}` (a no-op when there is no
    row). An `execute/2` rerun that finds the row already there skips the
    machine check and parks, so a machine that is briefly unknown or
    outdated after a hub restart can't end a call whose op may be running.
    A raise inside `execute/2` or `resume/2` is rescued by
    `Durable.ToolTask` and recorded as an error; that commit now runs the
    tool's `on_interrupt/2` too, as an abort or a failure does. (Why: a call
    that ended with its row open and not canceled leaves an op the next join
    starts, after the model was told the call failed, so a retry runs the
    command twice. `HubOps-bug-error-skips-cancel.cfg`.)
11. While a call waits on an online machine, each recheck (once a minute)
    asks the channel to push its op again (`{:push_op, op_id}`). The channel
    builds it with `push_for/2` as in rule 2, so a row that finished or was
    canceled meanwhile gets nothing. On the node this is idempotent (node
    rules 1 to 3): it resends the latest snapshot, or resumes an op nothing
    runs. This is what recovers a lost `op.start` or snapshot when the
    connection didn't drop, for example when the node failed to journal or
    the channel crashed on one message.
12. The hub's own machine, `local`, has no node key. When `config :photon,
    :local_node` is true, `Machines.status/1` and `Machines.roster/0` treat
    it as known whether or not it is connected, so a call on it parks while
    it is offline (at hub boot the durable harness reruns calls before the
    endpoint and the local node start) instead of failing as unknown.

On the node:

1. `op.start` for an op with no journal and `known: false` writes the journal
   (`ready` snapshot, fsynced) and then starts the op process. Nothing runs
   before the journal is on disk.
2. `op.start` for an op that has a journal is a request for the latest
   snapshot. The node sends the journaled snapshot. If the snapshot isn't
   terminal and no process is running for it (the node restarted and hasn't
   resumed it yet), it resumes the op from the journal, which never reruns a
   shell command (see `Ops.Shell`'s recovery). Every resume, from here,
   from the executor's start-up scan or from a restart after an op process
   exited cleanly (`Executor.Rules.down/3`), reads the journal's `cancel`
   flag: when it is set, the executor follows `Ops.add/2` with
   `Ops.cancel/1`, and so it does when the scan finds a running op whose
   journal says canceled (the executor may have died between journaling a
   cancel and telling the process). It doesn't instead advance the
   snapshot to `canceling`: `Ops.Shell` starting in `canceling` kills only
   the snapshot's `pgid` and skips the `pid` file, so a command started
   just before a crash would be reported canceled while it ran on. (Why: a
   cancel journaled while no process ran, for example in the window after
   an op process exited before its terminal snapshot, would otherwise be
   lost, and the resumed command would run to completion after the user
   stopped it.)
3. `op.start` for an op with no journal and `known: true` means the node lost
   it (its data directory was wiped or reset). The node does not run it. It
   answers with a `failed` snapshot: "The machine has no record of this
   operation. It may or may not have run." That snapshot isn't journaled.
4. A shell command spawns only after its `process` checkpoint is journaled,
   and only if the journal doesn't say canceled. This keeps the
   at-most-once guarantee (TLA finding F3) without a hub round trip.
5. Every snapshot is journaled before it is forwarded to the hub. The
   journal always holds the latest snapshot.
6. A terminal journal stays until `op.ack`. Then `op.json`, `pid` and `exit`
   are deleted. `out` and `err` stay for 7 days, because a truncated result
   names their paths; a daily sweep removes op directories that have no
   `op.json` and are older than that.
7. `op.cancel` for a journaled, unfinished op records the cancel in the
   journal and tells the process. For an op with no journal it journals a
   `canceled` snapshot ("canceled before it started") and sends it; like any
   terminal journal it stays until `op.ack`, so an `op.start` that arrives
   later gets that snapshot back (rule 2) and runs nothing. `op.cancel` for
   a finished op changes nothing. `op.ack` for an unknown or unfinished op
   is ignored. (Why journal it: the hub sends `op.cancel` from inside its
   commit, and if a hub crash rolls that commit back, the next join sends
   `op.start` for the same op. A node that didn't keep the cancel would then
   run a command the user had stopped. `HubOps-bug-cancel-unjournaled.cfg`.)
8. A journal write that fails never runs anything. If the `ready` entry for
   `op.start` can't be written, the node answers with an unjournaled
   `failed` snapshot ("The machine couldn't record the operation: <reason>.
   It didn't run.") and starts no process. A failed write for the `process`
   checkpoint makes `checkpoint/2` return `{:error, reason}`, and
   `Ops.Shell` fails the op without spawning (rule 4). A failed write for
   any later snapshot is logged and the snapshot is forwarded anyway, and
   the journal keeps the older one. A terminal snapshot forwarded that way
   (and the `failed` answer for a `ready` entry that couldn't be written)
   is held in the executor's memory until `op.ack`: every decision reads
   it in place of the journal's entry, so `op.start` gets it back, a
   join sends it, a clean exit of the op process restarts nothing, and the
   ack forgets it. If the older entry is `ready` (the op hasn't started),
   the executor also deletes it (`Executor.Rules.on_unjournaled/1`), since
   a resume from `ready` would start the op after the hub was told how it
   ended; after a restart the node then has no entry, and an `op.start`
   with `known: true` gets the rule 3 answer. From any later entry a
   resume only reports the outcome again (`Ops.Shell` recovers a started
   command from its files), and hub rule 5 acks a second terminal
   snapshot. If the `canceled`
   entry for an `op.cancel` with no journal (rule 7) can't be written, the
   node sends nothing: an unjournaled answer would let a later `op.start`
   run the op, and the hub sends `op.cancel` again on the next join. `Connection` and
   `NodeChannel` don't swallow errors from the executor or `Machines`: a
   failed call crashes them, the socket closes, and the rejoin resends
   everything (section 2.4).
9. No snapshot is larger than 6 MB as JSON, under the hub's 8 MB frame
   limit. Output bounds count code points, and a NUL encodes as `\u0000`
   (6 bytes), so two streams of 1,000,000 code points can reach 12 MB.
   Before journaling a snapshot, the executor encodes it, and if it is
   over the budget, `Executor.Request.fit/2` (pure) cuts `out` and `err`
   further by bytes, keeping the head, the tail and the marker with the
   full file's path. A `view_image` snapshot is already under 5 MB
   (`max_size`). (Why: the hub closes the socket on an oversized frame,
   the node reconnects and resends every journaled snapshot on join,
   including that one, and the machine flaps for good while the call waits
   with no timeout.)
10. A node that stops on purpose (its supervisor shuts down, which is what
    a hub restart does to the local node) kills its running commands, and
    says so. `Ops.Shell.terminate/2` writes a `stopped` file in the op's
    directory before it signals the group. On resume, `recover/1` checks
    for it before the `exit` file and fails the op: "photon-node stopped
    while the command was running, so the command was killed." It appends
    the exit status when the `exit` file has one. Without the marker the
    wrapper, which is outside the killed group, records exit 143, and the
    resumed op would report a `completed` command with partial output.

### 2.4 What happens when

Hub restart.
Parked tool calls stay parked in the database. Each wakes at its next check
(section 3.3), or when its signal fires. A call that was in `execute/2`
reruns (the tools are `replay: :safe`) and asks for the same op to be
pushed; the channel sends `op.start` only if the row is still open. A call
that was in `resume/2` reruns it; `resume/2` only reads durable state and
commits, so it is idempotent. The node keeps running its ops while the hub
is down, journals their snapshots, and drops the forwards. When it rejoins,
it sends every journaled snapshot, and the hub sends `op.start` or
`op.cancel` for its open rows. Results recorded twice are impossible
(rule 4, rule 5).

Node restart.
The executor scans the journal on start. Unfinished ops are resumed, and
told to cancel if their journal says so (node rule 2): `Ops.Shell`
reattaches to a command that is still running, finishes one whose `exit`
file exists, and fails one whose outcome is unknown. A `view_image` job
simply runs again, since it only reads. Terminal ops wait for the next
join and its ack. A node that is stopped on purpose kills its running
commands' process groups on the way down, as today, so for the hub's own
machine a hub restart ends its running commands. The result says so:
"photon-node stopped while the command was running, so the command was
killed" (node rule 10). Only an abrupt crash (power loss, `kill -9` of the
VM) leaves commands running to be reattached.

Executor restart.
The executor and the `Connection` restart; op processes keep running.
An op's calls into the executor never kill it: `report` and `checkpoint`
wait as long as the executor lives and return `:down` or `:ignored` if it
dies (section 4.2). The restarted executor re-monitors running ops, asks
each to resend its snapshot, and resumes the rest from the journal.

Disconnect.
Nothing is lost. The node's ops keep running; snapshots are journaled and
the forwards are dropped while the connection is down. Live output is lost
for that stretch. On rejoin both sides resend what they hold (above).

Cancel during a disconnect.
The cancel is a durable fact on the op row (`cancel`). The tool call ends at
once with "Stopped by the user". When the machine rejoins, the hub sends
`op.cancel`. If the node had the op, it kills it and reports `canceled`; if
it never got `op.start`, it journals and answers "canceled before it
started", so an `op.start` still in flight can't run it. Either way the row
is closed and acked, and the node forgets the op.

Offline machine.
A call on a machine that is known but offline still records its op row and
parks. `op.start` goes out when the machine joins. If the machine stays
offline for 10 minutes, the call ends with an error result and the row is
canceled (rule 7). The message depends on whether the node ever saw the op:

The message is chosen inside the commit that ends the call (hub rule 7),
from the row and the registry as they are then:

- never pushed and never confirmed: "mm1 has been offline for 10 minutes,
  so the command didn't run. It won't run when mm1 comes back."
- pushed or confirmed, and mm1 still offline: "mm1 went offline after the
  command was sent and hasn't been back for 10 minutes. The command may
  have run, and may still be running there; if it is, it will be stopped
  when mm1 reconnects."
- pushed or confirmed, and mm1 connected again just now: "mm1 was offline
  for 10 minutes and has just come back. The command may have started; it
  is being stopped."

Only the first says the command didn't run, and only when that is
certain: an `op.start` never left the hub. The other two leave the model
to check the machine before it retries something that isn't safe to run
twice.

A call on a machine the hub doesn't know (no node key, not online, and not
`local` on a hub that runs its own node) fails at once and lists the
machines it does know. A machine that is online but
lacks the `"ops:1"` capability fails at once: "mm1 runs an older
photon-node that can't take commands. Reinstall it from the Nodes page."

Hub restart during the offline wait.
The offline clock is kept in the parked call's state (`offline_since`), so
it survives. It is only an approximation: the call checks once a minute, so
a machine that drops and returns between two checks never counts as
offline.

## 3. Blip's machine tools

### 3.1 The tools

Three `Photon.Durable.Tool` modules in a new `Photon.MachineTools` boundary,
outside `Photon.Assistant` because step 2's threads use them too. All three
are `replay: :safe`.

`shell`
- Description: runs one command with the machine's default shell, in the
  machine's workspace (step 1), in its own process group; stdin is
  `/dev/null`; background children are killed when the command exits,
  `nohup` or not; something meant to keep running starts in its own
  process group (`bash -c 'set -m; nohup CMD >CMD.log 2>&1 &'`, section
  3.7); the call returns when the command finishes.
- Parameters: `machine` (string, required, an ID from `list_machines`),
  `command` (string, required, at most 100,000 bytes), `max_output_length`
  (integer, optional, 1 to 1,000,000, default 40,000).

`view_image`
- Description: shows the model an image file on a machine (PNG, JPEG, GIF,
  WebP; up to about 3.7 MB of image data).
- Parameters: `machine` (string, required), `path` (string, required;
  absolute, or relative to the machine's workspace).

`list_machines`
- No parameters. Lists every machine the hub knows: online ones from the
  registry with platform, hostname, workspace and photon-node version, then
  known offline ones from `Photon.NodeKeys` (keys not revoked). `local` is
  listed as "this hub's own computer", online or not, whenever the hub runs
  its own node (hub rule 12). It replaces `list_nodes` (PR A keeps
  both; PR B deletes `list_nodes`).

### 3.2 How a call runs

`shell` and `view_image` share `Photon.MachineTools.Call`. Its `execute`:

1. Check the arguments with `Photon.MachineTools.Translate` (pure). A bad
   argument is an error result.
2. Derive the op ID with `Photon.MachineTools.Wait.op_id/1`.
3. If `Photon.Machines.op_state/1` finds a row for it (this is a rerun after
   a hub restart), go to step 5: the op may be running, so the machine's
   state no longer decides anything (hub rule 10).
4. Ask `Photon.Machines.status/1` about the machine: `:online`, `:offline`,
   `:outdated` or `:unknown` (`local` is never unknown on a hub that runs
   its own node, hub rule 12). Unknown and outdated are error results.
5. `Photon.Machines.start/1` commits the op row (idempotent; only while the
   task is unfinished and not marked for abort, hub rule 9) and, if the
   machine is online, asks its channel to push the op (hub rule 2). If it
   returns `{:error, :stopped}` (the task is ending), the call ends with an
   error result ("The call was stopped before it reached mm1.").
6. Park: `{:wait, %{"signal" => "op:" <> op_id, "until" => until}, state}`.
   `until` and `offline_since` come from `Wait.first/3` (pure), given
   whether the machine is online now. The state is
   `%{"op_id", "machine", "kind", "summary", "offline_since"}`, where
   `summary` is the command or path for the UI and `offline_since` is the
   time the call first saw the machine offline, or null.

Its `resume(state, api)`:

1. Read the row: `Photon.Machines.op_state/1` returns `{:finished,
   snapshot}`, `{:open, confirmed?}`, `:closed`, or `:none` when there is
   no row.
2. Finished: return `{:commit, fun}`. Inside the commit,
   `Machines.claim_tx/2` marks the row closed and clears its snapshot, and
   the result is `{:ok, Translate.result/3, Translate.details/3}` of the
   snapshot. If `claim_tx/2` finds nothing to claim there, the result is
   the error of step 4.
3. Open: `Wait.next/4` decides from the state, whether the machine is online
   now, the time, and the limits: `{:park, until, state}` or `:give_up`.
   - Park while online: first ask the channel to push the op again
     (`Machines.repush/1`, hub rule 11), then re-park (`{:wait, ...}`;
     online clears `offline_since`).
   - Park while offline: re-park with `offline_since` set.
   - Give up (offline past the limit): `{:commit, fun}`. Inside the commit,
     `Machines.abandon_tx/2` reads the row and the registry again and
     applies `Machines.Rules.on_abandon/2`. An open row gets `cancel`, and
     `op.cancel` goes to the channel if one is registered now (hub rule 7);
     `abandon_tx` returns `{:abandoned, facts}` (`pushed`, `confirmed`,
     `online`), and `Wait.offline_message/3` (pure) picks the text from
     section 2.4, naming the offline limit it is given. A row that finished meanwhile is claimed the way
     `claim_tx` does it (`{:claimed, snapshot}`), and the call returns the
     real result instead of the offline error.
4. Closed: only possible if the result was already recorded, which also
   finishes the task. Return an error result ("This result was already
   delivered.") as a guard. No row: an error result ("The hub has no record
   of this operation on mm1.").

Its `on_interrupt(api, tx)` (user Stop, a failed task, or a raise that
`ToolTask` rescued) calls `Machines.cancel_tx(tx, op_id)`: sets `cancel`
on the row if it is open and sends `op.cancel` if the machine's channel is
registered; closes the row and clears its snapshot if it is finished (hub
rule 7). Every error result `Call` returns from step 2 of `execute` on, or
from `resume`, goes through the same `cancel_tx` in its commit (hub rule
10).

That send happens inside the Store commit. If the commit then rolled back
(a hub crash), the node has already journaled the cancel, so it never runs
the op, and reports `canceled`. The row records that as its result. The
task is still marked for abort, so after the restart it ends with "Stopped
by the user" as before, and this time the commit closes the row. The
durable flag covers the case that matters, an offline machine.

`resume/2` reruns after a hub restart with no replay check
(`Photon.Durable.ToolTask`). It reads only durable state and does its writes
in its final commit, so a rerun is harmless.

### 3.3 Wait limits

- Check interval while parked: 60 seconds. Each check that finds the machine
  online asks for the op to be pushed again and re-parks: per running call,
  one `push_for/2` commit, one small `op.start` and the node's reply, and
  one re-park commit a minute.
- Offline limit: 10 minutes, counted from `offline_since`.
- While offline, `until` is the earlier of the next check and
  `offline_since + limit`.
- Both come from `config :photon, Photon.MachineTools, check_ms:,
  offline_limit_ms:`, read by `Call` and passed to `Wait`, so tests can use
  milliseconds.
- There is no limit on how long an online machine may run a command.

### 3.4 Results and output bounds

`Translate.result(kind, snapshot, machine)` returns the tool result's
content (message parts), ported from the node's `Tools.Bash.format/2` and
`Tools.ViewImage.format/2`; `Translate.details/3` returns its details. A
failed or canceled op is still an ok result whose text starts with
`Error:`, so its details reach the UI.

Shell, completed:
- stdout, then `Stderr:` and stderr, then `Exit code: N` when not 0, or
  `(no output)` when there is none.
- Each stream is bounded on the node to `max_output_length` code points
  (head and tail around a marker giving the omitted size and the path of the
  full file on that machine). The hub bounds each field again with
  `PhotonCore.Output.bound!/3` at the same limit plus 1,000 code points of
  room for the node's marker, so a misbehaving node can't flood the model
  and a well-behaved node's truncated output isn't cut a second time. The
  limit is the snapshot's `max_output_length` (the call's own), capped at
  1,000,000, or 40,000 if the snapshot has none.

Shell, failed or canceled: `Error: <terminal_error>`, bounded the same way.

View image, completed: `[Message.image(mime, base64), Message.text("<w>x<h> <mime>, <path> on <machine>")]`.
The hub checks the mime is one of the four supported and the base64 is at
most `max_size` before passing it on. Over the size, the node already fails
the op with a hint to make a smaller copy.

Details stored with each result, for the UI: `machine`, `op_id`, `kind`,
`command` or `path`, `status`, `exit_code`, `out_truncated` or
`err_truncated`, and for shell results `full_output` (where `out` and
`err` are kept on the machine, for section 3.6). No image data in
details.

Live output: the node samples new output once a second, at most 64 KB per
stream per sample (unchanged). The hub forwards each `op.output` as
`Durable.live(conversation_id, %{"type" => "tool_output", "call_id",
"stream", "text"})` and stores nothing. `Assistant.Transcript.tool_output/2`
keeps the last 8,000 characters per call. The node socket gets an explicit
`max_frame_size` of 8 MB in `PhotonWeb.Endpoint`, enough for a 5 MB image
snapshot, so the limit is a decision rather than a default. The node keeps
every snapshot under 6 MB of JSON (node rule 9), and a command is at most
100,000 bytes, so no message it sends comes near the limit.

### 3.5 The hub's own machine

Nothing new is needed. `Photon.Application.local_node/0` already starts
`{PhotonNode, node_id: "local", token: NodeKeys.local_token(), data_dir:
Photon.Paths.local_node_dir(), ...}` inside the hub's VM, dialing the hub's
own endpoint. In PR A that node gains the executor like any other. Blip
reaches it as `machine: "local"`, and `list_machines` says what it is. Its
workspace is `<local node dir>/workspace`.

### 3.6 Older results in Blip's context

Blip is one conversation that only a "fresh start" resets, and
`Durable.Context` sends every tool result since the last reset. Until now
raw command output stayed in node sessions and Blip saw summaries. From
this step each `shell` result (40,000 code points by default) and each
`view_image` result (up to about 5 MB of base64) would stay in every later
request, and a few dozen commands or a handful of screenshots would push
requests past the model's context or the request size limit.

So `Durable.Context.messages/1` shortens tool results from before the
newest `user` entry, that is, from earlier turns:

- an image part is replaced by "(image no longer shown; call view_image
  again to see it)"; the dimensions line stays
- text over 4,000 code points keeps its first and last 2,000 around a
  marker: "...N characters of this older result left out. <hint>...",
  where the hint is the result's `details["full_output"]` when the tool
  set one, for example "Full output: /data/ops/op_x/out and
  /data/ops/op_x/err on mm1, kept for 7 days."

Results in the current turn stay whole, so the model sees what it just
asked for. The cut moves only when a new turn starts, so a turn's
requests share a stable prefix for prompt caching. The rule is generic
(every tool's old results), stays in the strict core, and takes nothing
from the profile. `Translate.details/3` sets `full_output` for shell
results.

### 3.7 Prompt and mock model

`Photon.Assistant.Prompt`, "How you work":

- PR A: add that Blip has `shell` and `view_image` on every machine and
  should use them for anything short (checks, reading files, one-off
  commands), and `run_on_node` only for long autonomous work. Each `shell`
  call is a fresh shell in the machine's workspace. Background children
  are killed with the command's process group when it exits, and `nohup`
  alone doesn't help, since its child stays in that group. Commands that
  would run for hours (servers, watchers) start as a job in their own
  process group, with output to a file: `bash -c 'set -m; nohup CMD
  >CMD.log 2>&1 &'` (bash's job control puts the job in a new group
  before it returns; `setsid` can still be in the old group when the
  group is killed, and macOS has no `setsid`). The `shell` description
  says the same.
- PR A also changes the voice block, since Blip now runs commands
  itself: "You do not run commands yourself. You hand work to ...
  machines, each of which has its own agent" becomes "You run commands on
  <owner> machines yourself, and you report back what actually happened.",
  and the "never" line "Claim to have run something yourself. You
  delegated it. Say who ran it." becomes "Say something ran without naming
  the machine it ran on." BlipLive's empty state says the same. The block
  is copied from the Blip brand kit's `VOICE.md`; say in the PR
  description that the kit needs the same edit.
- PR B: drop the node-agent lines entirely.

`Photon.Assistant.MockScript` (the scripted model behind
`PHOTON_MOCK_MODEL=1` and the tests) learns:

- `machines` and `list machines` call `list_machines` (PR A changes them
  from `list_nodes`); `nodes` and `list nodes` keep calling `list_nodes`
  until PR B
- `on <machine>: $ <command>` calls `shell`
- `on <machine>: look at <path>` calls `view_image`
- after a machine tool result, it relays the result text, and for an image
  says "Here it is." with the dimensions line

PR A keeps `on <machine>: <task>` (anything not starting with `$` or
`look at`) for `run_on_node`; PR B deletes it. Update the `@help` text to
match.

## 4. Module plan

Layers per the brief: data, functional core (strict Boundary, no I/O),
boundary, lifecycle, workers. "Registered names" lists names a module adds.

### 4.1 apps/core

| Module | Layer | Boundary | Notes |
|---|---|---|---|
| `PhotonCore.Output` | core | inside `PhotonCore` (strict, pure); exported | Moved from `PhotonNode.Harness.Output` unchanged (PR A). |
| `PhotonCore.Operation` | data and core | inside `PhotonCore`; exported | Moved from `PhotonNode.Harness.Operation` (PR A). Adds `new/5` taking the ID as its first argument, and `statuses/0` (every status, for `Wire`'s snapshot check). `new/4`, which mints an ID with `PhotonCore.ID.new/1`, stays in PR A for the node's session tools (allow-listed in core's `FunctionalCore` check) and is removed in PR B. |
| `PhotonCore.Operation.Wire` | data and core | inside `PhotonCore`; exported | New (PR A). Builders and parsers for each message in section 2.2: `start/4`, `cancel/1`, `ack/1`, `snapshot/1`, `output/3`, and `parse_start/1`, `parse_id/1`, `parse_snapshot/1`, `parse_output/1`, each returning `{:ok, map}` or `{:error, reason}` and ignoring unknown fields. Builders return `{event, payload}`, the push shape `Machines.Rules` uses. Event names are module attributes behind `event/1` (`:start`, `:cancel`, `:ack`, `:snapshot`, `:output`), which both sides use; a handler that matches on an event binds it at compile time (`@snapshot Wire.event(:snapshot)`). Parsers check shapes only: `op.start` takes any `kind` and `args` map (the node's `Executor.Request` judges them), and every op ID must start with `op_` and pass `PhotonCore.ID.valid?/1`, since the node names a directory after it. |

Deleted in PR B: `PhotonCore.LLM.Relay`, `PhotonCore.LLM.Relay.Wire`,
`PhotonCore.LLM.MockAgent`, and the relay provider in `PhotonCore.LLM`.
`PhotonCore.LLM.Mock` stays (the hub's `MockScript` implements it). Update
`PhotonCore`'s moduledoc and `exports`.

### 4.2 apps/node

PR A adds the executor next to sessions. Operation processes report to an
owner, a behaviour, so the session coordinator and the executor can both
own operations until PR B.

| Module | Layer | Boundary | PR | Notes |
|---|---|---|---|---|
| `PhotonNode.Harness.Ops.Owner` (PR B: `PhotonNode.Ops.Owner`) | contract | in the Ops boundary | A | Behaviour: `checkpoint(owner_id, op) :: :ok \| :cancel \| :ignored \| {:error, String.t()}` (a call; persist before acting), `report(owner_id, op) :: :ok \| :down` (persist, then forward), `output(owner_id, op_id, stream, text) :: :ok` (live). The callback docs say what every implementation must keep: an op process never dies because of its owner. `checkpoint` and `report` return `:ignored` and `:down` on any exit from the owner, not only `:noproc`, since an uncaught exit in `Ops.Shell` runs its `terminate/2`, which kills the command. An op process is started with `{op, {owner_module, owner_id}}`. The module is named in data, so Boundary sees no call from Ops to its owners, which avoids a dependency cycle. `Owner.checkpoint/2`, `report/2` and `output/4` take the pair and call the module, so op processes call those (`Owner.t()` is the pair). `stream` is the string `"out"` or `"err"`, as `Wire.output/3` takes it. Stays in PR B with one real implementation (the executor) and a test owner. |
| `PhotonNode.Harness.Ops`, `Ops.Shell`, `Ops.Job`, `Ops.ViewImage` | boundary / workers | Harness (PR B: own `PhotonNode.Ops` boundary, exporting `Owner`) | A, B | PR A: replace the `session_id` argument with the owner pair; replace direct calls to `Coordinator.checkpoint/2`, `Coordinator.report_op/2` and `Link.live/2` with the owner's callbacks. `Shell.start_when_confirmed/2` fails the op on `{:error, reason}` without spawning. `Shell.terminate/2` writes the `stopped` marker before it kills a running group (whenever the command's port is still open, including during a cancel's kill; a kill under way after the command exited is only for its leftover children and writes none), and kills the group found through the `pid` file when the `pgid` checkpoint hasn't happened yet. `recover/1` checks the marker before the `exit` file (node rule 10), and a fresh start removes a stale one with the other leftover files. `Ops.running?/1` says whether a process runs an op, for `Executor.Rules`' `running?` argument (A5). The Harness boundary's `exports` become `[Link, Ops, Ops.Owner, Env]`, since the Executor, a separate boundary, calls `Ops.add/2`, `Ops.running?/1` and `Ops.cancel/1`, implements `Ops.Owner` and reads `Env.shell/0` for `Request`'s facts. PR B: rename to `PhotonNode.Ops.*`, delete `SkillUse`, move `Env` and `Image` with them. |
| `PhotonNode.Harness.Coordinator` | boundary | Harness | A (then deleted in B) | Implements `Ops.Owner` with its session ID as `owner_id`: `checkpoint` is today's `checkpoint/2`, now returning `:ignored` rather than `:down` on an exit, as the behaviour says; `report` is `report_op/2`, renamed `report/2`; `output` is `Link.live/2` with the `op_output` map. |
| `PhotonNode.Executor` | boundary (API plus GenServer) | own boundary: `deps: [PhotonNode, PhotonNode.Config, PhotonNode.Harness (PR B: PhotonNode.Ops), PhotonCore, Jason], exports: [Link]` | A | The node's API for hub ops: `start/1` (a parsed `op.start`), `cancel/1`, `ack/1`, `snapshots/0` (every journaled snapshot, for a join), plus the `Ops.Owner` callbacks. One process. It owns the journal (all writes go through it, so a cancel flag and a snapshot can't overwrite each other), monitors every op process it starts (rule 87), answers `process` checkpoints, and forwards snapshots and output through `Executor.Link`. On `:DOWN` it applies `Executor.Rules.down/3`. The owner callbacks `report/2` and `checkpoint/2` call the executor with `:infinity` as the timeout and catch every exit (`catch :exit, _`), returning `:down` and `:ignored`, as `Coordinator.checkpoint/2` does today. A call that waits on a busy executor (a journal scan, an fsync of a 5 MB image snapshot) just waits; one whose executor dies returns at once, since `GenServer.call` monitors it. The executor never calls an op process synchronously (`Ops.add/2` starts a child whose `init/1` returns at once, or sends `:resend`), so the wait can't deadlock. The op process keeps its state, and the restarted executor's `Ops.add/2` asks it to resend. The moduledoc says so: an op process never dies because of its owner. `init/1` returns at once; `handle_continue` scans the journal, applies `Executor.Rules.on_scan/2` to each entry, calls `Ops.add/2` for every unfinished op (a running one is asked to resend, a missing one resumes from its snapshot), follows it with `Ops.cancel/1` when the entry's `cancel` flag is set (node rule 2), and monitors it. Snapshots are encoded and fitted to the 6 MB budget with `Request.fit/2` before they are journaled (node rule 9). A failed journal write is handled as node rule 8 says. A daily `send_after(:sweep)` removes acknowledged op directories older than 7 days; the first sweep runs after the start-up scan. Registered name: `PhotonNode.Executor`. As built (A5): `start/1`, `cancel/1`, `ack/1` and `snapshots/0` are calls with `:infinity` as the timeout, so a dead executor fails them at once and a busy one is waited for; the ops it owns carry the owner pair `{PhotonNode.Executor, :hub}`; `output/4` goes from the op process straight to `Executor.Link`, never through the executor; a `ready` snapshot is forwarded after it is journaled, so the hub learns the op arrived; an op process that `Ops.add/2` can't start, or that crashes, is failed with `Request.failed/2`; an exit of a process that has since been replaced (the op is monitored again under a newer pid) is ignored. Entries that exist but can't be read: `op.start` answers with the unjournaled `Request.unreadable/2` unless a process runs the op (its next snapshot replaces the entry), `op.ack` then forgets the entry, `op.cancel` only tells the process, `checkpoint` returns `{:error, reason}`, and a report is forwarded without journaling. A report for an op whose entry is terminal or missing changes nothing. A terminal snapshot that can't be journaled (and an `unrecorded` answer) is held in memory until its `op.ack` and read in place of the journal's entry by every decision and by `snapshots/0`; a `ready` entry it leaves behind is deleted with `Journal.discard/2` when `Rules.on_unjournaled/1` says so (node rule 8). |
| `PhotonNode.Executor.Journal` | boundary helper (file I/O, no process) | inside Executor | A | Each takes the ops dir first. `read(ops_dir, id) :: {:ok, entry \| nil} \| {:error, String.t()}` (nil: no entry; an unreadable file or one that isn't an entry for `id` is an error); `write(ops_dir, id, entry) :: :ok \| {:error, String.t()}` (to `op.json.tmp`, mode 0600, synced, renamed over `op.json`, then the directory synced, and the ops dir too when the op's directory was new; the op's directory is mode 0700). Erlang can't open a directory to fsync it, so on Linux the directory sync runs `sync -- <dirs>` (coreutils and busybox fsync each path); elsewhere it is skipped. An error means the old entry is still in place: once the rename has happened, a failed directory sync is only logged. `list(ops_dir) :: [entry]` in ID order, logging and skipping unreadable entries; `forget(ops_dir, id)` (deletes `op.json`, `op.json.tmp`, `pid`, `exit` and `stopped`); `discard(ops_dir, id)` (deletes `op.json` alone and syncs the directory, for node rule 8); `sweep(ops_dir, now, max_age) :: [id]` (POSIX seconds; removes directories with no `op.json` whose mtime is older than `now - max_age`; `forget/2` changes the mtime, so the age counts from the ack); `op_dir/2`. File shape: `%{"op" => snapshot, "cancel" => boolean}`. Called only from the executor process. Until A5 adds the Executor boundary it sits in the `PhotonNode` boundary. |
| `PhotonNode.Executor.Request` | core | strict, `deps: [PhotonCore, Jason]` | A | `operation(start_message, facts) :: {:ok, Operation.t()} \| {:error, String.t()}`. `facts` are `%{shell, ops_dir, workspace}`. Fills the shell op's `input` (`command`, `shell`, `directory`: the given directory or the workspace) and `base_directory` (`ops_dir`), or the view_image op's absolute `path` and `max_size`. A relative `directory` is taken from the workspace. `max_size` must be at most 5,000,000, so an image snapshot stays under the frame limit (`fit/2` can't cut an image). Also `rejected(start, reason)` (the `failed` snapshot for an `op.start` that `operation/2` refused: an unsupported kind or bad args), `lost(id, kind)` (the `failed` snapshot for rule 3), `never_started(id)` (the `canceled` snapshot for rule 7; `op.cancel` carries no kind, so its type is `"unknown"` and the hub reads the kind from its row), `unrecorded(op, reason)` (the `failed` snapshot for a `ready` entry that couldn't be written, node rule 8), `snapshot_budget/0` (6,000,000 bytes), `failed(op, message)` (the `failed` snapshot the executor records for an op process that crashed or couldn't start, with the message where the hub reads it), `unreadable(start, reason)` (the unjournaled `failed` answer to an `op.start` whose entry exists but can't be read: "It may or may not have run."), and `fit(snapshot, budget_bytes) :: snapshot`, which cuts `result.out`, `result.err` and `terminal_error` by encoded bytes, keeping head, tail and a marker with the byte count left out of the full output (`out_size`/`err_size`) and the file's path, until the JSON encoding fits (node rule 9); an existing marker is replaced, not kept twice, and `out_truncated`/`err_truncated` are set. Each answer carries its message in `terminal_error`, and a `view_image` one also in `result.error`, where the image job puts its reason. |
| `PhotonNode.Executor.Rules` | core | strict, `deps: [PhotonCore]` | A | Every resume decision, each aware of the journal entry's `cancel` flag (node rule 2). `on_start(journal_entry_or_nil, known?, running?) :: :run \| {:resend, cancel?} \| {:resume, cancel?} \| :lost` (a terminal entry gives `{:resend, false}`: the journaled snapshot is sent again and nothing is canceled); `on_scan(journal_entry, running?) :: :skip \| {:resend, cancel?} \| {:resume, cancel?}` (terminal entries are skipped and wait for their ack); `down(journal_entry_or_nil, reason, restarted?) :: :ignore \| {:restart, cancel?} \| {:fail, message}` (no entry or terminal: ignore; `:normal`, `:shutdown` or `:noproc` before a terminal snapshot: restart once; anything else, or a second clean exit: fail with "the operation process exited: ..."; this is `Session.op_down/3`'s rule, F9). `cancel?` true means the executor follows `Ops.add/2` with `Ops.cancel/1`. `on_unjournaled(journal_entry_or_nil) :: :remove \| :keep`: what happens to the entry when a terminal snapshot for it couldn't be journaled (node rule 8): a `ready` entry is removed, any other kept. |
| `PhotonNode.Executor.Link` | contract | exported by Executor | A | Behaviour: `snapshot(op) :: :ok`, `output(op_id, stream, text) :: :ok`. The implementation is the node config's `:link` (default `PhotonNode.Connection`), so tests can stand in. Replaces `PhotonNode.Harness.Link` in PR B. |
| `PhotonNode.Connection` | boundary (Slipstream) | adds `PhotonNode.Executor` to deps | A, B | PR A: handles `op.start`, `op.cancel`, `op.ack` by parsing with `Operation.Wire` and calling the executor; implements `Executor.Link` (plain sends to itself, dropped unless joined); after each join pushes `Executor.snapshots/0`; adds `"ops:1"` to `capabilities`. It doesn't catch failures from the executor: a failed call crashes it and the rejoin resends everything (node rule 8). PR B: removes every session handler, the `sent` offsets and replay, and the `Harness.Link` implementation; capabilities become `["ops:1"]`. As built (A6): the `Link` callbacks send `{:op_snapshot, op}` and `{:op_output, id, stream, text}` to the connection, which pushes them with `Wire.snapshot/1` and `Wire.output/3` only while joined; an `op.*` payload that `Wire` can't parse is logged and ignored, like an unknown event; the join's snapshots are pushed after the session replay, in ID order. |
| `PhotonNode.Config` | data | unchanged | A, B | PR A: add `ops_dir/1` (`<data_dir>/ops`). PR B: remove `heartbeat_ms`, `sessions_dir/1`, `llm_base_url/1`, the `llm` setting and `PHOTON_HEARTBEAT_MS`. `:link` stays. |
| `PhotonNode` | lifecycle | PR B drops `PhotonCore.LLM` and `PhotonCore.LLM.Error` from deps | A, B | PR A children: `SessionRegistry`, `OpRegistry`, `TaskSupervisor`, `OpSupervisor`, `SessionSupervisor`, `Executor`, `Connection`, `:resume`. PR B children: `OpRegistry`, `OpSupervisor`, `Executor`, `Connection`, still `:rest_for_one`. `init/1` creates the ops dir and the workspace. Rewrite the moduledoc: the protocol summary (pointing at `PhotonCore.Operation.Wire` and this plan) and the lifecycle plan in section 7. |
| `PhotonNode.CLI` | boundary | unchanged | B | Usage text: "runs commands on this machine for a Photon hub"; the workspace is "where commands run". |

Registered names after PR B: `PhotonNode.OpRegistry` (owners `PhotonNode`,
`PhotonNode.Ops`), `PhotonNode.OpSupervisor` (renamed from
`PhotonNode.Harness.OpSupervisor`; owners `PhotonNode`, `PhotonNode.Ops`),
`PhotonNode.Executor` (named only by `PhotonNode` and itself),
`PhotonNode.Connection` (unchanged), `PhotonNode.AppSupervisor`
(unchanged). The Executor and the Connection are registered under their
own module names, so they aren't in `ProcessNameOwnership`'s `names`:
every call to their APIs names the module, and the check would flag those
calls.

### 4.3 apps/hub

| Module | Layer | Boundary | PR | Notes |
|---|---|---|---|---|
| `Photon.Machines` | boundary (API, no process) | `deps: [Photon.Durable, Photon.NodeKeys, Photon.Nodes (PR B: none), Photon.Repo, PhotonCore, Ecto]`, exports none of its internals; root `Photon` exports `Machines` | A, B | The context for machines and their operations. `start/1`, `repush/1`, `status/1`, `op_state/1`, `claim_tx/2`, `abandon_tx/2`, `cancel_tx/2`, `roster/0`, `signal_key/1`, and for the channel `joined/1`, `push_for/2`, `snapshot/3`, `output/3`. `start/1` takes `%{id, machine, kind, args, task_id, conversation_id, call_id}` and returns `:ok`, or `{:error, :stopped}` with nothing inserted or pushed when the task has ended or is marked for abort. `op_state/1` returns `:none` when there is no row. `claim_tx/2` returns the snapshot or nil; `abandon_tx/2` returns `{:claimed, snapshot}` or `{:abandoned, facts}`; `repush/1` returns `:ok` or `{:error, :offline \| :not_found}`. `push_for(machine, op_id)` takes the channel's machine and returns nothing for another machine's row. `snapshot(machine, payload, routes)` returns `{pushes, routes}` and `output(machine, payload, routes)` returns `routes`: the channel's cache of where each op's live output goes, which `output/3` fills for open rows of that machine and `snapshot/3` drops an op from on its terminal snapshot. The signal is `signal_key(op_id)` = `"op:" <> op_id`, with payload `%{"status" => "finished" \| "closed"}`. Known machines are the node IDs from `NodeKeys.list/0` without `revoked_at`. Validates node payloads once with `Operation.Wire` (rule 64). Every write goes through `Photon.Durable.Store` (`Durable.commit/1`): it reads the row (and, for `start/1`, the task), calls the matching `Machines.Rules` function and applies what it returns, in one commit. So do the channel's reads (`joined/1`, `push_for/2`), which wait for a commit in progress and record `pushed` (section 2.3, hub rule 2). The pushes to send come back as plain data and the channel sends them (rule 11); the sends from inside a commit (`cancel_tx`, `abandon_tx`) read the registry there. `start/1` and `repush/1` ask the channel to push with `Photon.Nodes.push_op/2` in PR A. `status/1` and `roster/0` pass `local_node?` (`config :photon, :local_node`) to the core, so `local` is known whenever the hub runs its own node (hub rule 12). PR B folds `Photon.Nodes` in (registry, `list/0`, `get/1`, `online?/1`, `register/2`, `unregister/1`, `command/3`, `subscribe/0`, `broadcast/0`), and renames `Photon.NodeRegistry` to `Photon.MachineRegistry`, with `push_op/2` in place of `Photon.Nodes.push_op/2`. |
| `Photon.Machines.Op` | data (Ecto schema) | its own strict boundary, `use Boundary, type: :strict, deps: [Ecto]`, as `Photon.NodeSessions.Session` does, so `Machines.Rules` can name it | A | Table `machine_ops`: `id` (string, primary key), `machine`, `kind`, `args` (map), `conversation_id`, `call_id`, `task_id`, `status` (`open`, `finished`, `closed`), `confirmed` (boolean), `pushed` (boolean: an `op.start` was built for it at least once), `cancel` (boolean), `result` (map, null unless finished), timestamps. Index on `{machine, status}`. |
| `Photon.Machines.Rules` | core | strict, `deps: [Photon.Machines.Op, PhotonCore]` | A | Section 2.3's hub rules as functions; `Machines` reads, calls one, and applies the result, and `test/core/machines/rules_test.exs` covers each. A `write` is `:none`, a map of the row changes to make, or `{:finish, changes}` for a terminal snapshot (the changes set `status` to `finished` with the snapshot in `result`, or `closed` with no result if the row was canceled; the commit that applies them also fires the signal); a push is `{event, payload}`. `insert?(task_status, abort_requested?) :: boolean` (rule 9; `task_status` is nil when the task is gone); `push_for(row) :: {write, [push]}` (rule 2: `op.start` and `pushed` for an open row without `cancel`, nothing otherwise); `on_join([row]) :: {[{op_id, changes}], [push]}` (rules 2 and 7; writes name their rows, and rows that aren't open get nothing); `on_snapshot(row_or_nil, machine, snapshot) :: {write, [push]} \| :foreign` (rules 3 to 6; `:foreign` for another machine's row, which `Machines` logs and ignores); `on_claim(row) :: {write, snapshot}` (rule 8; `{:none, nil}` for a row that isn't finished); `on_cancel(row, online?) :: {write, [push]}` (rule 7: `cancel` and `op.cancel` for an open row, close and clear a finished one); `on_abandon(row, online?) :: {:claimed, snapshot, write} \| {:abandoned, facts, write, [push]}` (rule 7, with `facts` = `%{pushed: boolean, confirmed: boolean, online: boolean}` for the message; a closed row or no row is abandoned with no write or push). |
| `Photon.Machines.Roster` | core | strict, `deps: []` | A | `build(online_infos, known_ids, local_node?) :: [%{id, online, info}]`, the local machine first, then the connected ones by ID, then the known offline ones by ID; `known_ids` are plain strings from `NodeKeys` (keys not revoked), and `local_node?` adds `local` as known even while it's offline. Also `status(machine, online_info_or_nil, known_ids, local_node?) :: :online \| :offline \| :outdated \| :unknown`. Replaces `Photon.Nodes.roster/2` in PR B. |
| `Photon.Nodes` | boundary | unchanged | A (folded into Machines in B) | New `push_op(node_id, op_id) :: :ok \| {:error, :offline}`: sends `{:push_op, op_id}` to the node's registered channel. Only `Photon.Machines` calls it. Its `PreferCall` reason covers it (section 4.4). |
| `Photon.MachineTools` | boundary | `deps: [Photon.Durable, Photon.Machines, PhotonCore]`, `exports: []` | A | Module doc, `tools/0` returning the three tool modules, and the `signal_key/1` helper. |
| `Photon.MachineTools.Shell`, `.ViewImage`, `.ListMachines` | boundary (durable tools) | inside MachineTools | A | Section 3.1. `Shell` and `ViewImage` delegate to `Call`. |
| `Photon.MachineTools.Call` | boundary | inside MachineTools | A | Section 3.2: `execute/3`, `resume/2`, `on_interrupt/2`, reading the limits from config. |
| `Photon.MachineTools.Translate` | core | strict, `deps: [PhotonCore]` | A | `shell_args/1`, `view_image_args/1` (ported checks: limit range, NUL bytes, blank command or path, and a command over 100,000 bytes; return op `args` with `directory: nil`, and for `view_image` `max_size` from `max_size/0`), `result/3` (section 3.4; the content parts, so `Call` returns `{:ok, result, details}`), `details/3` (string keys: `machine`, `op_id`, `kind`, `status`, then `command`, `exit_code`, `out_truncated`, `err_truncated` and `full_output` for shell, or `path` for view_image; `full_output` is set only when the snapshot has both output paths, section 3.6), and the error texts `unknown_machine(machine, known_ids)` and `outdated_machine(machine)`. |
| `Photon.MachineTools.Wait` | core | strict, `deps: []` | A | `op_id/1` (`t_<suffix>` to `op_<suffix>`), `first(online?, now, limits) :: {until, offline_since}` (`offline_since` is `now` when offline, nil when online; `Call` puts it in its state), `next(state, online?, now, limits) :: {:park, until, state} \| :give_up` (gives up once `now - offline_since` reaches the limit, so a limit of 0 gives up at the first offline sighting), and `offline_message(machine, facts, limit_ms)` with the three texts of section 2.4 (`facts` from `abandon_tx`), naming the limit ("10 minutes", or "250 milliseconds" in tests). Times are Unix milliseconds; `limits` is `%{check_ms:, offline_limit_ms:}`. Time and limits are arguments (rule 29). |
| `PhotonWeb.NodeChannel` | boundary (Phoenix channel, the per-node server) | unchanged | A, B | PR A: `handle_in("op.snapshot")` and `handle_in("op.output")` call `Machines.snapshot/3` and `Machines.output/3` and push what they return; `handle_info(:joined)` also pushes `Machines.joined/1`; a new `{:push_op, op_id}` clause pushes what `Machines.push_for/2` returns, and the `{:command, event, payload}` clause already pushes `op.cancel`. A new clause before the generic one drops `{:command, "op.start", _}` with a log line, so the channel never pushes an `op.start` built by another process. It doesn't catch failures from `Machines`: a failed call crashes the channel, and the node's rejoin resends everything (node rule 8). Live output routes (`op_id` to conversation and call) are cached in the `routes` assign, which `Machines.snapshot/3` and `output/3` take and return; an op is dropped from it on its terminal snapshot. Each callback stays within 15 lines (rule 30). PR B: removes `event`, `live` and `input_rejected`, the `pushed_inputs` and `sessions` assigns, and the `sync` reply. |
| `PhotonWeb.Endpoint` | lifecycle config | unchanged | A | `max_frame_size: 8_000_000` on the `/node` socket's websocket options. PR B removes `plug PhotonWeb.NodeAuthPlug`. |
| `Photon.Assistant` | boundary | adds `Photon.MachineTools` to deps; PR B drops `Photon.NodeSessions` and `Photon.Nodes` | A, B | `@tools` gains `MachineTools.tools()` (PR A) and loses the node tools (PR B). Moduledoc updated. |
| `Photon.Assistant.Transcript` | core | unchanged | A | `tool_output(outputs, event)` folds each `tool_output` event into a map of the last 8,000 characters per `call_id` (both streams, in the order they came). It is a function of its own, not a `live/2` clause, because `BlipLive` clears the in-flight answer when the assistant entry that makes a call commits, which is before the call prints anything; `BlipLive` keeps the map in its own `outputs` assign and drops a call's tail when its result comes. `action_status/3` shows a machine op whose details say `canceled` as stopped (`failed` was already an error). Tool results with image parts are kept for rendering. |
| `PhotonWeb.BlipLive` | server (LiveView) | unchanged | A, B | PR A: labels and icons for `shell` ("Ran `<command>` on <machine>"), `view_image` ("Looked at <path> on <machine>") and `list_machines`, taken from the call's arguments (an error result has no details); a non-zero `exit_code` shows as a badge; a running call shows its live output tail under its line; an image result renders under its line as a data-URI `img`, borrowing `SessionLive`'s rendering of `NodeTranscript`'s view_image items. PR B: removes session links, node-report rendering and the four node tools' labels. |
| `Photon.Durable.Context` | core | unchanged | A | `messages/1` shortens tool results from before the newest `user` entry (section 3.6). Moduledoc updated. |
| `Photon.Durable.ToolTask` | boundary | unchanged | A | A raise rescued in `call_tool/2` is recorded in a commit that also runs `interrupted(task, tx)`, so the tool's `on_interrupt/2` sees every failure (hub rule 10). For `run_on_node` until PR B that means `NodeWork.ensure_watcher/2` also runs after a raise, which is what it is for. Moduledoc and `Photon.Durable.Tool`'s `on_interrupt` doc updated. |

Registered names: none new in PR A (`Photon.Machines` reaches channels
through `Photon.Nodes.push_op/2` and `Photon.Nodes.command/3`, which own
`Photon.NodeRegistry`). PR B renames `Photon.NodeRegistry` to
`Photon.MachineRegistry`, owned by `Photon.Application` and
`Photon.Machines`.

Migration (PR A): `apps/hub/priv/repo/migrations/20261006000000_create_machine_ops.exs`.
Add `machine_ops` to `@tables` in `apps/hub/test/support/data_case.ex`.

### 4.4 Credo and Boundary lists

PR A:
- `apps/core/.credo.exs`: add `PhotonCore.Output`, `PhotonCore.Operation`,
  `PhotonCore.Operation.Wire` to `FunctionalCore` (with the `PhotonCore.ID.new`
  allowance for `PhotonCore.Operation` until PR B).
- `apps/node/.credo.exs`: remove `PhotonNode.Harness.Operation` and
  `PhotonNode.Harness.Output` from `FunctionalCore` and its allow list; add
  `PhotonNode.Executor.Request` and `PhotonNode.Executor.Rules`; add
  `"PhotonNode.Executor"` to `ProcessNameOwnership`'s `api_modules` (not
  to its `names`: the process is registered under its module's name, as
  `PhotonNode.Connection` is, and the check flags every reference to a
  listed name, so `Connection`'s calls to `Executor.start/1` would fail
  it); reword the `PreferCall` reason for `PhotonNode.Connection`
  to cover snapshots ("lost snapshots are resent from the journal after
  every join").
- `apps/hub/.credo.exs`: add `Photon.Machines.Op`, `Photon.Machines.Rules`,
  `Photon.Machines.Roster`, `Photon.MachineTools.Translate`,
  `Photon.MachineTools.Wait` to `FunctionalCore`; add `"Photon.Machines"` to
  `ProcessNameOwnership` `api_modules`; reword `Photon.Nodes`'s `PreferCall`
  reason to cover `push_op/2` ("command/3 and push_op/2: ops are rows,
  pushed again on every join and every minute while their call waits on an
  online machine; inputs stay queued in the NodeSessions outbox").
- `lib/photon.ex`: export `Machines`.

PR B:
- node: drop `Session`, `Context`, `Inbox`, `SkillPrompt`, `Tools.*` from
  `FunctionalCore`; drop `SessionRegistry`, `TaskSupervisor`,
  `SessionSupervisor` from `ProcessNameOwnership`, rename the op names to
  `PhotonNode.Ops*`; set `api_modules` to `PhotonNode.Ops` and
  `PhotonNode.Executor`; drop the Coordinator `PreferCall` entry; re-justify
  `PhotonNode.Ops` (":resend and :cancel to a local op process, which the
  executor monitors"); move the `NoSleep` entry to `PhotonNode.Ops.Shell`;
  drop the `PhotonCore.ID.new` allowances.
- hub: drop `Assistant.Report`, `NodeSessions.*`, `NodeTranscript` from
  `FunctionalCore`; drop `Photon.NodeSessions` and `Photon.Nodes` from
  `api_modules`; rename the registry entry; replace the `Photon.Nodes`
  `PreferCall` entry with `Photon.Machines` ("command/3, push_op/2 and
  register/2: callers must not wait on a node's connection; ops are rows
  pushed again on every join and every minute while their call waits, and a
  replaced connection is waited for"); delete the
  `PhotonWeb.ModelRelayController` entry.
- `lib/photon.ex`: drop `NodeSessions`, `NodeSessions.Session`,
  `NodeTranscript`, `Nodes` from exports; rewrite the moduledoc.

## 5. What PR A adds and PR B deletes

### 5.1 PR A: the protocol and machine tools, next to sessions

Adds everything in section 4 marked A. Removes nothing visible. After PR A:

- A node runs both protocols: session messages go to the harness, `op.*` to
  the executor. Its session ops (`<data_dir>/sessions/operations/...`) and
  hub ops (`<data_dir>/ops/...`) don't share a directory.
- Blip has `shell`, `view_image`, `list_machines`, and still `run_on_node`
  and the other node-session tools.
- The new migration adds `machine_ops`; nothing else in the database changes.

### 5.2 PR B: delete sessions, the relay and the agent loop

Database: fresh start. Delete
`apps/hub/priv/repo/migrations/20261003000100_create_node_sessions.exs`; do
not add a drop migration. The PR description tells the user to delete the
hub's database file and reinstall every node (`PHOTON_PURGE=1` on the
install script also removes the node's old `sessions` directory). Nothing in
the code migrates or reads old rows.

Hub deletions:
- Blip's node tools: `apps/hub/lib/photon/assistant/tools/{run_on_node,message_node_session,check_node_session,stop_node_session,list_nodes}.ex`,
  `assistant/node_work.ex`, `assistant/node_watch.ex`, `assistant/report.ex`;
  the `node_watch` kind in `config/config.exs` and `config/test.exs`.
- The report half of `Assistant.Transcript` (`settle/3` for `node_report`,
  `report?`, `went_wrong?`), `Assistant.Notice`'s node-session statuses and
  failures (it keeps Blip's own failures), `Assistant.Page`'s session
  context (`session_id/1`, `of_session/1` and the session branches of
  `note/2`, `label/1`, `strip/1`), and `background_input?/1`'s
  `"node_report"` source (`"routine"` stays).
- `Photon.NodeSessions` and `node_sessions/{mirror,session,input,event}.ex`;
  `Photon.NodeTranscript`; `Photon.Settings.node_config/1`;
  `PhotonWeb.SessionLive` and its route; `Photon.Nodes` (folded into
  `Photon.Machines`).
- The model relay: `PhotonWeb.ModelRelayController`,
  `PhotonWeb.NodeAuthPlug` and its plug in the endpoint, the
  `post "/llm/stream"` route (the `/node` scope keeps `install.sh` and
  `download`), and `config :photon_node, llm: ...` in
  `apps/hub/config/test.exs`.

Hub UI, left coherent:
- Sidebar (`layouts.ex`): Machines lists machines with their online state
  from `Machines.roster/0`, linking to the Nodes page; no per-node session
  links, no `{:session, id}` active state, no `session_badge`.
- Overview (`overview_live.ex`): machines (online and known offline) and a
  line pointing at Blip for work; no running or recent sessions, no
  `/sessions` links; the "nowhere to send work" copy becomes "No machines
  yet. Add one from the Nodes page."
- Nodes (`nodes_live.ex`): no Sessions field or count, no
  `:node_sessions_changed`; "Its sessions stay here" copy removed.
- Blip (`blip_live.ex`): no `/sessions` links in bubbles, notices, sources
  or details; no `node_report` source rendering; `page_at/1` no longer
  looks up sessions; no `:node_sessions_changed` handler.
- `PhotonWeb.Shell`: no `NodeSessions.subscribe/0`, no `sessions` or
  `working` assigns; `nodes` comes from `Machines.roster/0`.

Node deletions: `harness.ex`, `harness/{session,coordinator,store,context,inbox,model_request,link,skills,skill_prompt,tools}.ex`,
`harness/tools/`, `harness/ops/skill_use.ex`, `priv/prompts/`; the session
handlers in `connection.ex`; `SessionRegistry`, `TaskSupervisor`,
`SessionSupervisor` and the `:resume` task in `photon_node.ex`;
`:session` logger metadata in `apps/node/config/config.exs` (use `:op`);
`config :photon_node, llm:` in `apps/node/config/test.exs`. Then rename
`PhotonNode.Harness.Ops*`, `Env` and `Image` to `PhotonNode.Ops*`.

Core deletions: section 4.1.

Specs (`specs/tla/`):
- Delete `NodeSync.tla`, `NodeSync.md` and every `NodeSync*.cfg`.
- Replace `Coordinator.tla` and `Coordinator.md` with `Executor.tla` and
  `Executor.md`, keeping only the op-process part with the executor as the
  checkpoint sink: actions `OpInit`, `OpSpawn`, `OpCancelAck`, `PidLine`,
  `PortExit`, `OpCancel`, `OpResend`, `Poll`, `CmdExit`, `BgExit`,
  `OpCrash`, and properties `AtMostOnceExec`, `CallResult`. Keep the bug
  configs for F3, F8, F9, F11 and K1 under new names
  (`Executor-bug-double-exec.cfg`, `-cancel-before-pid`, `-op-crash`,
  `-bg-reattach`, `-pid-file`). Delete the session-only configs
  (`-crash-loses-input`, `-idle-stop-loses-input`, `-not-resumed`,
  `-orphan-llm`, `-stop-forgotten`, `-stop-swallows-input`, `-tool-vanish`,
  `-inputs`, `-witness` if it only witnesses session paths).
- `Durable.tla` and `Durable.md`: replace the node-work actions (`NodeRun`,
  `NodeCreateWatcher`, `NodeWait`, `NodeResume`, `WatchStart`,
  `WatchReport`, `NodeSettle`) with a machine tool: execute (row, park),
  terminal signal, periodic recheck, offline abandon, Stop with cancel flag.
  Replace `NoDoubleDelivery`, `ReportsNotWithdrawn` and
  `DeliveredOnceAnswered` with `OneResultPerCall` (the call's result is
  recorded once) and `ClaimedOnce` (a finished op's result reaches at most
  one tool result). Delete the watcher configs
  (`Durable-{crash-watcher,stop-watcher,delivery,delivery-ok,fixresume,fixes}.cfg`)
  or rewrite those whose fault still exists (`-double`, `-stop`, `-crash`).
- `docs/verification.md`: rewrite the coverage section, and in the NS-* and
  F* tables mark NodeSync and session findings as retired with the code they
  covered; keep the rows for findings still covered (F3, F8, F9, F11, K1 and
  the durable core).

Docs: `docs/architecture.md` (module map), `AGENTS.md` (the layout lines for
`apps/core` and `apps/node`), and a note at the top of
`docs/unreal-agent-port-spec.md` that the session parts were removed in this
step and only the operation layer remains.

## 6. Test plan

General rules: core logic is tested in `test/core` with plain inputs (rule
52). Boundary tests go through the public API and `assert_receive`, use
`start_supervised!/1`, never sleep (rule 55), and don't retest core tables
(rule 53). Wait for a process to finish with a monitor and
`assert_receive {:DOWN, ...}`, and synchronize with `:sys.get_state/1`.

### 6.1 PR A

apps/core
- `test/core/output_test.exs`, `test/property/output_property_test.exs`:
  moved from the node.
- `test/core/operation_test.exs`: moved; add `new/5`.
- `test/core/operation/wire_test.exs`: each builder and parser; unknown
  fields are ignored; missing or mistyped fields give `{:error, reason}`;
  a snapshot round-trips through JSON.

apps/node
- `test/core/executor/request_test.exs`: shell fills shell, ops dir and
  workspace; a given directory wins; a relative image path joins the
  directory or workspace; an unknown kind and bad args are errors; `rejected/2`,
  `lost/2`, `never_started/1` and `unrecorded/2` shapes; `fit/2` on a worst-case
  snapshot (a 100,000-byte command, and `out` and `err` each 1,000,000 NUL
  code points) encodes to at most 6 MB and keeps both markers and paths,
  and a snapshot already under the budget comes back unchanged.
- `test/core/executor/rules_test.exs`: every row of `on_start/3`,
  `on_scan/2` and `down/3`, each with the entry's `cancel` flag false and
  true.
- `test/property/journal_property_test.exs`: random sequences of writes,
  torn tmp files and crashes between write and rename (repurposing
  `store_property_test.exs`'s idea): `read/2` always returns the last fully
  written entry.
- `test/boundary/executor_test.exs`, with `PhotonNode` started with
  `connect: false` and a test link sending snapshots and output to the test
  process:
  - a shell op journals `ready`, then reports `awaiting` and `completed`
    with its output; the journal holds each snapshot before the test sees it
  - a repeated `start/1` (known false, then true) sends the latest snapshot
    and never runs the command twice (the command appends to a file; the
    file has one line)
  - `known: true` with no journal gives the "no record" failure and runs
    nothing
  - cancel during a run gives `canceled`; cancel of an unknown op journals
    and sends the "canceled before it started" snapshot, and a `start/1`
    for it afterwards (known false) resends that snapshot and runs nothing
    until `ack/1`; a cancel journaled before the `process` checkpoint means
    the command never spawns
  - `ack/1` removes `op.json` and keeps `out` and `err`; the sweep removes
    old directories without `op.json`
  - killing an op process with `:kill` gives a `failed` snapshot (F9); a
    clean exit before a terminal snapshot restarts it once
  - killing the executor leaves the command running; the restarted executor
    re-monitors it and the result still arrives once
  - killing the executor while an op's `report` call waits on it (the test
    link blocks the executor until the test lets it go) leaves the command
    running, and its result arrives once from the restarted executor
  - a cancel journaled while no op process runs is not lost: journal an
    `awaiting` op with `cancel: true` whose process group the test started
    itself, start `PhotonNode`, and the scan's resume kills the group and
    reports `canceled`
  - stopping the whole `PhotonNode` supervisor while `sleep 30` runs and
    starting it again on the same data dir gives one `failed` snapshot
    saying photon-node stopped and the command was killed (node rule 10),
    never `completed` with exit 143
  - reattach after an abrupt crash is covered the way `shell_test.exs` does
    it, without stopping a supervisor: journal an `awaiting` snapshot for a
    process group the test started, then start `PhotonNode`. With the
    `pgid` in the snapshot it is reattached (F11); with only a `pid` file it
    is found through that (K1); with an `exit` file it finishes as
    `completed`
  - an ops dir the executor can't write: `start/1` answers with the
    "couldn't record the operation" failure and runs nothing (node rule 8)
  - a `ready` entry whose `process` checkpoint can't be written (its
    `op.json.tmp` is a directory): the shell fails without running, the
    `ready` entry is removed, a repeated `op.start` gets the same result
    back and runs nothing, `snapshots/0` lists it until the ack; after an
    executor restart with the disk writable again, nothing runs and an
    `op.start` with `known: true` gets the rule 3 answer (node rule 8)
- `test/boundary/shell_test.exs` and `jobs_test.exs`: adapted to a test
  owner module implementing `Ops.Owner` that forwards to the test process
  and answers checkpoints from it. Keep the F3, F8, F11, K1 and
  responsive-kill tests. Add: an op stopped by its supervisor while its
  command runs leaves a `stopped` marker, and recovering it fails with the
  "photon-node stopped" message even though the `exit` file says 143.
- `test/boundary/recovery_test.exs`: unchanged in PR A except for the owner
  argument.
- `test/boundary/connection_test.exs`: `op.start`, `op.cancel`, `op.ack`
  reach the executor; after a join the journal's snapshots are pushed;
  snapshots and output are pushed only while joined; unknown events are
  ignored; the hello lists `"ops:1"`.

apps/hub
- `test/core/machines/rules_test.exs`: the table in section 2.3 (every row
  state crossed with terminal and non-terminal snapshots, unknown ops,
  another machine's op), `on_join/1` (start with `known` and `pushed` for
  open rows, cancel for canceled rows, nothing for closed ones),
  `push_for/1`, `insert?/2`, `on_claim/1`, `on_cancel/2` (open: `cancel`,
  plus `op.cancel` only when online; finished: closed and cleared) and
  `on_abandon/2` (open: `cancel` with the facts, and `op.cancel` when
  online; finished: claimed).
- `test/core/machines/roster_test.exs`: `local` is listed and its status
  is `:offline`, not `:unknown`, when `local_node?` is true and it isn't
  connected; it is unknown when `local_node?` is false.
- `test/core/machine_tools/translate_test.exs`: ported from the node's
  `test/core/tools_test.exs` (limit range, NUL bytes, blank path, each
  result shape), plus the hub's re-bounding, the image checks, the
  100,000-byte command cap, and `full_output` in shell details.
- `test/core/machine_tools/wait_test.exs`: `op_id/1`; park while online;
  first offline sighting sets `offline_since`; online clears it; past the
  limit gives `:give_up`; `offline_message/3` gives "didn't run" only when
  neither `pushed` nor `confirmed`, and the hedged texts otherwise (offline
  and online again); `until` never passes the limit.
- `test/core/durable/context_test.exs`: a conversation with many shell and
  image results: results before the newest `user` entry have no image
  parts and at most about 4,000 code points of text with the
  `full_output` hint; results in the current turn are whole; a call and
  its result still pair up.
- `test/property/machine_ops_property_test.exs`: random sequences of
  snapshot deliveries for a few ops (duplicates, stale non-terminal after
  terminal, reconnects that resend everything, cancels, tool claims)
  against `Photon.Machines` with the real database: each op is finished at
  most once, its signal fires exactly when it is finished, `op.ack` is
  returned only for ops whose row is finished or closed, and no `op.start`
  is returned for a canceled row.
- `test/boundary/machines_test.exs`: `start/1` commits a row and sends
  `{:push_op, id}` to an online machine (a test process registered as its
  connection through `Photon.Nodes.register/2`); offline sends nothing
  until `joined/1`; `start/1` for a task marked for abort or finished
  inserts nothing; `push_for/2` gives `op.start` with `known` from the row
  for an open row and nothing once the row is finished, closed or
  canceled (the stale-start trace: finish the row, then push), and sets
  `pushed` when it returns one; `repush/1` sends `{:push_op, id}` again;
  `status/1` for unknown and outdated machines, and `:offline` for `local`
  with `config :photon, :local_node` set and no node connected;
  `claim_tx/2`, `abandon_tx/2`, `cancel_tx/2` (including closing a finished
  row); `abandon_tx/2` with the test channel registered sends `op.cancel`
  and reports `online: true`; `output/3` broadcasts `tool_output` on the
  conversation's topic.
- `test/boundary/machine_tools_test.exs`, driving Blip's conversation in
  the durable harness (as `durable_test.exs` does) with a fake node joined
  through `Phoenix.ChannelTest`:
  - `shell` parks, the fake node answers `op.start` with a terminal
    snapshot, the call's result has the output and the node gets `op.ack`
  - a hub restart while parked (stop and restart the harness) and while in
    `execute` (rerun) sends the same op ID
  - an offline machine with millisecond limits ends with the "didn't run"
    message and sets `cancel`; the next join sends `op.cancel`, not
    `op.start`
  - the reconnect race at the limit: the call has read the machine as
    offline, the fake node joins and gets `op.start`, then the abandon
    commits (drive it by joining from inside a test `Wait` limit of 0, or
    by holding the Store with a commit the test controls): the node gets
    `op.cancel` and the message is the hedged one
  - while the machine stays online, each recheck pushes `op.start` again
    with `known` from the row, and a fake node that dropped the first one
    still gets the op run once
  - a call on `local` with `config :photon, :local_node` set and no local
    node connected parks rather than failing as unknown
  - a rerun of `execute` that finds the row already there parks without
    checking the machine, even if the machine is now unknown
  - a tool step that raises after the row exists (a test tool wrapping
    `Call` that raises in `resume/2`) ends with an error result, and the
    row has `cancel` set; the online node gets `op.cancel`
  - Stop sets `cancel` and the online node gets `op.cancel`
  - Stop after the result came in but before the call claimed it leaves
    the row closed with no snapshot
  - Stop keeps background input (the kept part of F6 from
    `node_work_test.exs`)
- `test/web/channels/node_channel_test.exs`: `op.snapshot` and `op.output`
  are handed to `Machines`; a node can't finish another node's op; the
  join pushes open ops; existing auth and takeover tests stay.
- `test/core/assistant/mock_script_test.exs`: the new phrasings.
- `test/core/assistant/transcript_test.exs`: `tool_output` keeps a bounded
  tail per call.
- `test/web/live/blip_live_test.exs`: a `shell` call renders with its
  machine name (`#blip` element IDs), live output appears under a running
  call, an image result renders as an `img`.
- `test/integration/machine_tools_e2e_test.exs`, the hub-plus-node test.
  It runs a real node against the real channel:
  - start the durable harness, and a Bandit listener for
    `PhotonWeb.Endpoint` on a free port (`port: 0`, read back with
    `ThousandIsland.listener_info/1`), since the test endpoint has
    `server: false`
  - `start_supervised!({PhotonNode, server: "ws://127.0.0.1:<port>/node/websocket", token: Photon.NodeKeys.local_token(), node_id: "local", data_dir: <tmp>})`
  - with the scripted model (`config :photon, :mock_model, true`, what
    `PHOTON_MOCK_MODEL=1` sets in development), submit
    `on local: $ echo hello` to Blip and wait for Blip's reply to contain
    `hello`
  - write a small PNG and submit `on local: look at <path>`; the tool
    result has an image part
  - submit `on local: $ sleep 1; echo done`, kill the node's
    `PhotonNode.Executor` while it runs (the `:rest_for_one` supervisor
    restarts the executor and the `Connection`; the command keeps running),
    and check the result arrives once with `done`. Do the same with the
    hub's side instead: stop the node's channel process, so the node
    rejoins
  - submit `on local: $ sleep 30`, stop the node's supervisor while it
    runs, start it again, and check that one result arrives saying
    photon-node stopped and the command was killed (node rule 10)
  - If Bandit can't serve the endpoint's socket in the test env, fall back
    to a bridge process that joins the channel with `Phoenix.ChannelTest`
    and relays between it and the node's executor through a test
    `Executor.Link`. Say which one was used in the test's moduledoc.
  - As built (A13): Bandit serves the node socket in the test env, so the
    bridge isn't used. The test also covers Stop while a command runs on
    the node (canceled, the row closed, the journal entry forgotten) and
    Stop while `local` is offline (the join's `op.cancel` is answered
    "canceled before it started", and nothing runs). Commands write a
    `runs` file in the node's workspace, so the tests also check each
    command ran once. The offline limit is a minute there, so a node
    restarted on purpose is back before a call gives up.

### 6.2 PR B

- Delete: hub `test/boundary/{node_sessions,node_work}_test.exs`,
  `test/property/node_sessions_property_test.exs`,
  `test/core/node_sessions/mirror_test.exs`,
  `test/core/node_transcript_test.exs`,
  `test/web/live/session_live_test.exs`,
  `test/web/controllers/model_relay_controller_test.exs`,
  `test/core/assistant/report_test.exs`; node `test/core/{session,context,inbox,model_request,tools}_test.exs`,
  `test/property/{session,coordinator_replay,context,inbox,store}_property_test.exs`,
  `test/boundary/{harness,skills}_test.exs`; core tests for the relay and
  `MockAgent`.
- Rewrite: hub `test/boundary/assistant_tools_test.exs` (drop the node-tool
  describes, keep schedules), `test/core/assistant/work_test.exs` (keep the
  routine parts), `test/core/assistant/{notice,page,transcript,mock_script}_test.exs`,
  `test/core/durable/tool_call_test.exs` (its two node-tool references),
  `test/boundary/assistant_test.exs`, `test/web/live/{blip_live,pages,overview_live,nodes_live}_test.exs`,
  `test/web/channels/node_channel_test.exs` (drop sync, ingest,
  input-once and the old cross-node session test).
- Node: `test/boundary/recovery_test.exs` keeps only the op tests, moved
  into `executor_test.exs` if they duplicate it; `test/support/` loses
  `session_driver.ex`, `test_script.ex` and the session parts of
  `harness_case.ex` and `fixtures.ex` (keep `shell_op/1`, `running/2`,
  `completed/2`).
- Hub test support: remove `node_sessions`, `node_events`, `node_inputs`
  from `data_case.ex`'s `@tables`, the `Mirror` alias in `case.ex`, the
  `Session` and `Input` fixtures in `fixtures.ex`.
- Add: `test/core/machines/roster_test.exs` covers known offline machines
  from keys; a LiveView test that no page links to `/sessions`.
- The PR A e2e test must pass unchanged.

### 6.3 Checks for both PRs

In every app the PR touches (both PRs touch all three: `apps/core`,
`apps/node`, `apps/hub`):

- `mix precommit` (compile with warnings as errors, Boundary, the type
  checker, unused deps, format, `credo --strict`, tests with warnings as
  errors)
- `mix dialyzer`; any new ignore entry has a reason comment
- `mix test --cover`: core at 95, node and hub at 85

Also:
- `cd apps/core && mix test ../../tools/credo_checks/test` if a credo
  check's lists or code changed
- TLC on every new or changed config (`specs/tla/*.md` give the command);
  each bug config must still find its bug and each clean config must pass
- After pulling, `mix deps.compile photon_core photon_node --force` and
  `mix compile --force` in `apps/hub` clear stale Boundary warnings about
  moved modules

## 7. OTP rules that apply

| Rule | Where it bites |
|---|---|
| 2 | `Photon.Machines` is an API over the registry and the database, with no process of its own. The core modules are libraries. |
| 3, 31, 89 | No hub process per operation: the parked durable task holds the call's state and the channel is already a process per node. On the node, one executor process for all hub ops, not one per op owner. The only per-op processes are the existing op workers (isolation: a crashing command handler can't take others down; latency: each waits on its own port). |
| 6 | `Photon.Machines` and `Photon.MachineTools` are each one API; their schema and core modules aren't exported. `PhotonNode.Executor` exports only its `Link` behaviour. |
| 11 | `NodeChannel` and `BlipLive` call `Photon.Machines` and `Photon.Assistant`; the channel pushes what `Machines` returns and decides nothing. The `LiveViewLogic` check forbids `Repo`, `Registry` and PubSub there. |
| 15 | Op rows store facts (`confirmed`, `cancel`, `status`, the terminal snapshot) and the signal records the finish. A tool call's wait state is derived from them on each resume. The node's journal stores each snapshot. |
| 16 | The executor isn't a get/put wrapper: it monitors ops, serializes journal writes and answers checkpoints. |
| 28, 29 | `Translate`, `Wait`, `Machines.Rules`, `Roster`, `Executor.Request`, `Executor.Rules`, `Operation`, `Operation.Wire` and `Output` are strict-Boundary pure modules. `Wait` takes the time and limits as arguments; `op_id/1` derives from the task ID. `Operation.new/4`'s ID minting is allow-listed until PR B removes it. |
| 30 | `NodeChannel`'s `handle_in` clauses, `Connection`'s `handle_message` and the executor's callbacks each hand the message to the API or core and stay within 15 lines. |
| 60, 61 | `Photon.Machines` is a boundary for side effects (pushes) and shared state (rows); it reuses the durable harness for waiting and the channel for transport, and adds no server. |
| 62, 83 | `PhotonNode.Executor` is one GenServer behind a thin API that never hands out pids. Its name is owned by `PhotonNode` and itself. The hub's registry is owned by `Photon.Nodes` in PR A and `Photon.Machines` in PR B. |
| 63 | Message formats stay behind client functions: `Executor.checkpoint/2` and `report/2`, `Connection`'s `Link` callbacks, `Ops.cancel/1`. Wire payloads are built only in `PhotonCore.Operation.Wire`. |
| 64 | Node payloads are parsed once, in `Photon.Machines`; hub payloads once, in the node's `Connection` (with `Operation.Wire`) and `Executor.Request`. Everything behind them trusts the data. |
| 67, 69 | `{:error, message}` results name the machine and what to do ("Reinstall it from the Nodes page"). `Machines` returns plain maps and tuples, not schemas or pids. |
| 71 | The executor interprets `Executor.Rules.on_start/3`, `on_scan/2` and `down/3` (run, resend, resume, restart, cancel or fail); `Call` interprets `Wait.next/4` (park or give up). |
| 72 | Checkpoints and reports from op processes to the executor are calls, with no timeout, and they catch every exit, so an op process never dies because of the executor. The deliberate sends, each allow-listed with its reason: `Connection`'s link callbacks (dropped while disconnected, recovered from the journal on join), `Ops`'s `:resend` and `:cancel` (the executor monitors the process), and the hub's `command/3` and `push_op/2` (ops are rows pushed again on join and on every online recheck). |
| 73 | Live output is the one high-volume path. The node samples once a second at most 64 KB per stream; the hub stores none of it; the transcript keeps 8,000 characters per call; the node socket's frame size is capped at 8 MB and no snapshot is over 6 MB of JSON. Re-park checks are, per running call, a re-push and two small commits a minute. Old tool results are shortened in Blip's context (section 3.6). |
| 75 | Both sides ignore unknown events and fields; `Wire` parsers drop extras. A node without `"ops:1"` is reported as outdated rather than waited on. |
| 79, 81, 84 | The node's children, in order: `OpRegistry`, `OpSupervisor`, `Executor`, `Connection` (PR B), `:rest_for_one`. An executor crash restarts only it and the connection; ops keep running and are re-monitored. An `OpSupervisor` crash takes the executor and connection with it; the executor resumes ops from the journal. Write this in `PhotonNode`'s moduledoc. |
| 80, 82 | The executor starts through `start_link` under `PhotonNode` and is `:permanent`. Op workers stay `:temporary` under `OpSupervisor`; the executor, not the supervisor, decides about restarts. |
| 86 | What each crash loses: a `NodeChannel` loses its registration and route cache, rebuilt on rejoin. The executor loses its monitors and restart counts, rebuilt in `handle_continue` from the registry and the journal, including each entry's `cancel` flag (a resumed or still-running op whose journal says canceled is told to cancel). Op processes don't lose anything when it dies: their calls into it return `:down` or `:ignored`. The connection loses nothing durable; it resends the journal on join. An op worker's crash becomes a `failed` snapshot. A node VM restart resumes from the journal; a shell command's outcome comes from its `stopped`, `exit` and `pid` files. |
| 87 | The executor monitors op processes and never links to them. |
| 92 | No new one-off jobs. The node's `:resume` task goes; the executor's `handle_continue` does the scan. |
| 96 | The executor's sweep uses `Process.send_after/3`. Tool rechecks use the durable `"until"`. Nothing sleeps; the only allowed sleep stays in `Ops.Shell.terminate/2`. |

## 8. Ordered tasks

Each task names its files and is small enough for one agent. Every task ends
with `mix precommit` passing in the apps it touched. "After" lists what must
be merged into the branch first.

### 8.1 PR A

A1. Move `Output` and `Operation` to core; add the wire module.
- Move `apps/node/lib/photon_node/harness/output.ex` to
  `apps/core/lib/photon_core/output.ex` and `harness/operation.ex` to
  `apps/core/lib/photon_core/operation.ex`; add `new/5`.
- New `apps/core/lib/photon_core/operation/wire.ex` (section 4.1, messages
  in section 2.2).
- Export `Operation`, `Operation.Wire`, `Output` from `PhotonCore`
  (`apps/core/lib/photon_core.ex`); update its moduledoc.
- Update every node reference (`Ops.Shell`, `Ops.Job`, `Ops.ViewImage`,
  `Session`, `Coordinator`, `Tools.*`, tests, fixtures) and the node's
  Boundary deps.
- Move `apps/node/test/core/{output,operation}_test.exs` and
  `test/property/output_property_test.exs` to apps/core; add
  `test/core/operation/wire_test.exs`.
- Credo lists in both apps (section 4.4).

A2. Give operation processes an owner. After A1.
- New `apps/node/lib/photon_node/harness/ops/owner.ex`.
- `harness/ops.ex`, `ops/shell.ex`, `ops/job.ex`: the owner pair replaces
  `session_id`; `Ops.add/2` takes `(op, owner)`.
- `harness/coordinator.ex`: implement `Ops.Owner`; pass
  `{Coordinator, session_id}` to `Ops.add/2`.
- `Shell.start_when_confirmed/2`: `{:error, reason}` fails the op without
  spawning.
- `Shell.terminate/2` and `recover/1`: the `stopped` marker (node rule 10).
- `harness.ex`: Boundary `exports: [Link, Ops, Ops.Owner, Env]`, so the
  Executor boundary (A5) can call `Ops.add/2` and `Ops.cancel/1`,
  implement `Ops.Owner` and read `Env.shell/0`.
- The `Owner` callback docs: `checkpoint` and `report` never let an exit
  from the owner reach the op process (section 4.2).
- Tests: `shell_test.exs` (plus the `stopped` marker case), `jobs_test.exs`,
  `recovery_test.exs` with a test owner in `test/support/`.

A3. Executor core. After A1.
- New `apps/node/lib/photon_node/executor/request.ex` (with `fit/2` and
  `unrecorded/2`) and `executor/rules.ex` (`on_start/3`, `on_scan/2`,
  `down/3`, each cancel-aware; node rule 2), per section 4.2.
- `apps/node/.credo.exs`: `Request` and `Rules` in `FunctionalCore` (the
  rest of section 4.4's node entries come with A5).
- Tests: `test/core/executor/{request,rules}_test.exs`.

A4. Executor journal. After A1.
- New `apps/node/lib/photon_node/executor/journal.ex`; `Config.ops_dir/1`
  in `config.ex`.
- Test: `test/property/journal_property_test.exs`, plus a small
  `test/boundary/journal_test.exs` for `list/1`, `forget/2` and `sweep/3`.

A5. The executor process. After A2, A3, A4.
- New `apps/node/lib/photon_node/executor.ex` and `executor/link.ex`:
  the owner callbacks with `:infinity` and `catch :exit, _`; `Ops.cancel/1`
  after every resume or resend the rules mark `cancel?`; snapshots fitted
  to 6 MB before journaling; journal write failures per node rule 8; the
  moduledoc says an op process never dies because of its owner.
- `photon_node.ex`: add `PhotonNode.Executor` after `SessionSupervisor` and
  before `Connection`; create the ops dir in `init/1`; extend the
  lifecycle section of the moduledoc.
- `.credo.exs` entries (section 4.4).
- Test: `test/boundary/executor_test.exs` (section 6.1), with a test link
  in `test/support/`.
- As built: `Ops.running?/1` in `harness/ops.ex`, and `Request.failed/2`
  and `Request.unreadable/2` (section 4.2); no `ProcessNameOwnership`
  `names` entry for the Executor (section 4.4); node rule 8 now says what
  a failed write of a "canceled before it started" entry does.

A6. Node connection speaks `op.*`. After A5.
- `apps/node/lib/photon_node/connection.ex`: the three hub messages, the
  `Executor.Link` callbacks, journal snapshots after each join,
  `"ops:1"` in `hello/0`; moduledoc. Failures from the executor crash the
  connection rather than being swallowed (node rule 8).
- `photon_node.ex` moduledoc: add the op protocol beside the session one.
- Test: `test/boundary/connection_test.exs`.
- As built: an `op.*` payload that doesn't parse is logged and ignored;
  `PhotonNode.Config`'s moduledoc says `:link` is also the executor's link
  (section 4.2).

A7. Hub op rows and rules. After A1.
- Migration `apps/hub/priv/repo/migrations/20261006000000_create_machine_ops.exs`.
- New `apps/hub/lib/photon/machines/op.ex` (its own strict boundary,
  `deps: [Ecto]`, with the `pushed` field), `machines/rules.ex` (every
  function in section 4.3's row, including `insert?/2`, `push_for/1`,
  `on_claim/1`, `on_cancel/2` and `on_abandon/2`), `machines/roster.ex`
  (`build/3` and `status/4`, with `local_node?`).
- `test/support/data_case.ex`: add `machine_ops` to `@tables`.
- Tests: `test/core/machines/{rules,roster}_test.exs`.

A8. `Photon.Machines` and the channel. After A7.
- New `apps/hub/lib/photon/machines.ex` (section 4.3), with `repush/1`
  and `abandon_tx/2` sending `op.cancel` from inside its commit.
- `apps/hub/lib/photon/nodes.ex`: `push_op/2`; moduledoc.
- `apps/hub/lib/photon_web/channels/node_channel.ex`: `op.snapshot`,
  `op.output`, joined pushes, `{:push_op, id}`, the clause that drops
  `{:command, "op.start", _}`, route cache; moduledoc.
- `apps/hub/lib/photon_web/endpoint.ex`: `max_frame_size` on `/node`.
- `apps/hub/lib/photon.ex`: export `Machines`; `apps/hub/.credo.exs`
  entries.
- Tests: `test/boundary/machines_test.exs`,
  `test/property/machine_ops_property_test.exs`, additions to
  `test/web/channels/node_channel_test.exs`.

A9. Machine tool core. After A1.
- New `apps/hub/lib/photon/machine_tools/translate.ex` (with the command
  cap and `full_output`) and `machine_tools/wait.ex` (`next/4` returning
  `:give_up`, and `offline_message/3`).
- Tests: `test/core/machine_tools/{translate,wait}_test.exs`.

A10. Machine tools for Blip. After A8, A9.
- New `apps/hub/lib/photon/machine_tools.ex`,
  `machine_tools/{call,shell,view_image,list_machines}.ex`. `Call` follows
  section 3.2 as written: the row check before the machine check, error
  results through `cancel_tx`, the re-push on an online recheck, and the
  offline message from `abandon_tx`'s facts.
- `apps/hub/lib/photon/assistant.ex`: deps and `@tools`; moduledoc.
- `assistant/prompt.ex`: the PR A lines from section 3.7.
- `assistant/mock_script.ex`: new phrasings and help text.
- `config/config.exs`, `config/test.exs`: `Photon.MachineTools` limits
  (test: short).
- Tests: `test/boundary/machine_tools_test.exs`,
  `test/core/assistant/mock_script_test.exs`.

A11. Durable: older results and raised tools. Independent of the rest.
- `apps/hub/lib/photon/durable/context.ex`: shorten tool results from
  earlier turns (section 3.6); moduledoc.
- `apps/hub/lib/photon/durable/tool_task.ex`: a rescued raise is recorded
  in a commit that also runs `interrupted(task, tx)` (hub rule 10);
  moduledoc, and the `on_interrupt` doc in `durable/tool.ex`.
- Tests: `test/core/durable/context_test.exs`; a `tool_task` boundary test
  where a tool with `on_interrupt/2` raises and its `on_interrupt` ran in
  the same commit as the error result.

A12. Blip's transcript for machine tools. After A10.
- `apps/hub/lib/photon/assistant/transcript.ex`: `tool_output`.
- `apps/hub/lib/photon_web/live/blip_live.ex`: labels, icons, live tail,
  image results.
- Tests: `test/core/assistant/transcript_test.exs`,
  `test/web/live/blip_live_test.exs`.

A13. Hub-plus-node test. After A6, A10.
- New `apps/hub/test/integration/machine_tools_e2e_test.exs` (section
  6.1); helpers in `apps/hub/test/support/` if needed.

A14. Spec and docs for the protocol. Can start after A5 and A8 are
designed; merge last.
- The spec is written: `specs/tla/HubOps.tla`, `HubOps.md` and its
  configs model this protocol, and found the problems behind hub rules 2,
  7, 9 and 10 and node rule 7. If the code departs from section 2, change
  the spec with it and rerun every config (`HubOps.md` gives the command
  and the expected result of each). Its bug configs include the four this
  task first named (`-bug-ack-early`, `-bug-no-known`,
  `-bug-start-after-cancel`, `-bug-spawn-before-journal`).
- `docs/verification.md`: a `HubOps` section.
- `docs/architecture.md`: add `Photon.Machines`, `Photon.MachineTools` and
  `PhotonNode.Executor`.
- As built (A14): the code was compared with section 2 and `HubOps.tla`
  action by action. No rule the spec models changed (node rule 8's added
  sentence covers a journal write failure, which the spec leaves out), so
  the spec's logic is unchanged and TLC wasn't rerun. `HubOps.md` gained
  "The code against the spec" (where the code's steps differ in shape,
  and why the spec covers them), the code's names (`push_for/2`,
  `snapshot/3`), a note on the executor crash the hub-plus-node test
  found, and corrupt journal entries under "Not modeled"; one comment in
  `HubOps.tla` names `snapshot/3`. `docs/architecture.md` also got the
  executor's place in the node's supervision tree, the step 1 rows of
  `Photon.Nodes`, `NodeChannel` and `Photon.Assistant`, and the new test
  support modules. `docs/verification.md` also lists the two new property
  tests and a table of H1 to H8 with the tests that pin each fix.

A15. Final checks. After all of the above.
- Section 6.3 in all three apps; run the e2e test; run Photon with
  `PHOTON_MOCK_MODEL=1` and check `on local: $ uname -a` in the Blip panel.

### 8.2 PR B

B1. Remove Blip's node-session tools.
- Delete the files listed in section 5.2 under "Blip's node tools".
- `apps/hub/lib/photon/assistant.ex`: `@tools`, deps (keep
  `Photon.Nodes` until B4), `background_input?/1`, moduledoc.
- `assistant/{prompt,mock_script,transcript,notice,page}.ex`: node-session
  parts out; prompt and voice per section 3.7.
- `config/config.exs`, `config/test.exs`: drop the `node_watch` kind.
- Tests per section 6.2; keep the F6 test in `machine_tools_test.exs`.

B2. Remove node sessions from the hub. After B1.
- Delete `lib/photon/node_sessions.ex`, `lib/photon/node_sessions/`,
  `lib/photon/node_transcript.ex`, `lib/photon_web/live/session_live.ex`,
  the `/sessions/:id` route, `Settings.node_config/1`, the node-sessions
  migration.
- Update `lib/photon_web/shell.ex`, `live/overview_live.ex`,
  `live/nodes_live.ex`, `components/layouts.ex`, `live/blip_live.ex` per
  section 5.2 (using `Photon.Nodes.list/0` and `Photon.NodeKeys` until B4).
- `lib/photon_web/channels/node_channel.ex`: drop `event`, `live`,
  `input_rejected`, `pushed_inputs`, `sessions`, the `sync` reply and
  `resend_queued`.
- `lib/photon.ex` exports and moduledoc; `.credo.exs` lists;
  `lib/photon/durable/store.ex` moduledoc mention.
- Tests and test support per section 6.2.

B3. Remove the model relay. Independent of B1 and B2.
- Delete `lib/photon_web/controllers/model_relay_controller.ex`,
  `lib/photon_web/node_auth_plug.ex`; edit `endpoint.ex` and `router.ex`.
- apps/core: delete `llm/relay.ex`, `llm/relay/wire.ex`, `llm/mock_agent.ex`
  and the relay provider in `llm.ex`; their tests; `PhotonCore` moduledoc.
- `apps/hub/config/test.exs`: drop `config :photon_node, llm:`.
- `.credo.exs`: drop the `ModelRelayController` entry.

B4. Fold `Photon.Nodes` into `Photon.Machines`. After B2.
- Move the registry functions into `lib/photon/machines.ex`; delete
  `lib/photon/nodes.ex`; rename `Photon.NodeRegistry` to
  `Photon.MachineRegistry` in `lib/photon/application.ex`.
- `Machines.roster/0` (online plus known keys) replaces `Nodes.roster/2`
  in `shell.ex`, `overview_live.ex`, `layouts.ex`, `nodes_live.ex` and
  `list_machines`.
- Update callers: `node_channel.ex`, `node_keys` callers if any,
  LiveViews, `lib/photon/provision.ex` (it calls `Nodes.subscribe/0` and
  `Nodes.get/1`: switch to `Machines.subscribe/0` and `Machines.get/1`,
  and replace `Photon.Nodes` with `Photon.Machines` in its Boundary deps),
  tests (`node_channel_test.exs`, `nodes_live_test.exs`,
  `overview_live_test.exs`, and any other test that names `Photon.Nodes`).
- `Photon.Nodes.push_op/2` becomes `Photon.Machines.push_op/2`.
- `lib/photon.ex`, `.credo.exs` (section 4.4).

B5. Remove the node's agent loop. After B3 (the node's `llm` config goes
with it).
- Delete the files in section 5.2 under "Node deletions".
- `connection.ex`: only `op.*`; capabilities `["ops:1"]`; moduledoc.
- `photon_node.ex`: children and moduledoc (section 7, rules 79, 81, 84);
  Boundary deps without `PhotonCore.LLM`.
- `config.ex`, `cli.ex`, `apps/node/config/{config,test}.exs`.
- Tests and support per section 6.2.

B6. Rename the operation layer. After B5.
- `PhotonNode.Harness.Ops*`, `Env`, `Image` to `PhotonNode.Ops*`
  (`lib/photon_node/ops.ex`, `lib/photon_node/ops/`), with its own
  Boundary exporting `Owner` and `Env` (the Executor reads
  `Env.shell/0`); `PhotonNode.Harness.OpSupervisor` to
  `PhotonNode.OpSupervisor`.
- `PhotonNode.Executor` deps; remove `Operation.new/4` from core and its
  credo allowance.
- `.credo.exs` in node and core (section 4.4).

B7. Specs. After B1 and B5 (they describe the deleted code).
- Section 5.2 "Specs": delete NodeSync, `Coordinator` to `Executor`,
  re-model `Durable`, rewrite `docs/verification.md`. Run TLC on every
  remaining config.

B8. Docs and final checks. After all of the above.
- `docs/architecture.md`, `AGENTS.md` layout lines,
  `docs/unreal-agent-port-spec.md` note.
- Section 6.3 in all three apps; the PR A e2e test; the PR description
  says to delete the hub database and reinstall nodes, and that the Blip
  brand kit's `VOICE.md` needs the voice edit PR A made (say it in PR A's
  description too).

## 9. Decisions for the user

None. The design doc and the brief settle everything this step needs. The
choices made here that the user may want to know about, all reversible:

- Shell commands have no timeout, as node sessions had none; Stop cancels.
- The offline limit is 10 minutes and the recheck is once a minute.
- A finished op's `out` and `err` files stay on the machine for 7 days after
  the hub acknowledges the result, so a truncated result's file path keeps
  working for a while.
- Blip's voice block changes two lines in PR A, which puts it out of step
  with the brand kit until `VOICE.md` gets the same edit.
- Tool results from earlier turns are shortened in Blip's context: images
  dropped, text cut to 4,000 code points with a pointer to the full output
  on the machine. Results in the current turn stay whole.
- A shell command is at most 100,000 bytes, below Linux's 128 KB limit on
  one argument.
