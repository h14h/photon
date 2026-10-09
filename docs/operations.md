# Operations: running work on machines

Every `shell` or `view_image` call is one operation (op) on one machine:
the hub records it, the node runs it, and the call waits durably for the
result. Contracts live in code: `PhotonCore.Operation.Wire`,
`Photon.Machines` (and `Machines.Rules`), `Photon.MachineTools.Call`,
`PhotonNode.Executor` and `PhotonNode.Ops.Shell`. `specs/tla/HubOps.md`,
`Executor.md` and `Durable.md` check the rules. Code cites them by number
("hub rule 7"), so retire a rule with a note rather than renumber.

## Guarantees

- A command runs at most once, however often `op.start` arrives and
  whoever restarts, as long as the node keeps its journal. A node that
  loses its data directory never reruns an op the hub had confirmed; one
  whose snapshots never reached the hub may run again (node rules 1 and 3).
- A lost message costs a delay, never the op. After every join the node
  resends every journaled snapshot, and the hub resends `op.start` or
  `op.cancel` for every open row.
- An op's result is recorded once and reaches at most one tool result.
- A canceled op never starts later, even if the cancel's commit rolls back.
- The node forgets an op only after the hub has durably recorded its result.
- The model hears "the command didn't run" only when that is certain.
- Ops keep running while the hub is down or the connection drops.

## Messages and versions

Messages travel on the node's channel `"node:<node_id>"`; `Wire` has their
fields. Both sides ignore unknown events and fields, so either side can be
updated first. The op ID is the tool task's ID with `t_` replaced by
`op_`: one call, one op, however often the call reruns. The node names a
directory after it, so `Wire` accepts only IDs safe as file names.

A node lists its protocol in the join's `capabilities`, today `ops:2`:
`ops:1` plus the promise that a `shell` op creates a missing working
directory (a project's folder is made on first use). A connected node
without `ops:2` is `:outdated`: it gets no ops, a new call on it fails at
once ("Reinstall it from the Nodes page"), and a call already waiting on
it ends that way at its next check. The join reply keeps an empty
`"sync"` map so nodes built before step 1 stay joined and show as outdated.

## Hub rules

1. The op ID is derived from the tool task ID. An `execute/2` rerun inserts
   nothing new (`on_conflict: :nothing`) and asks for the same op again.
2. Only the machine's channel builds `op.start`, from the row as it is at
   push time (`Machines.push_for/2`, and `joined/1` on every join), and only
   for an open row without `cancel`. Others ask with `push_op/2`; the
   channel drops a `{:command, "op.start", _}`. These reads are Store
   commits, so they wait for a commit in progress, and they set `pushed`.
   Only `HubOps-bug-unserialized-read` checks that wait (no ExUnit test can
   force the interleaving), so never turn these into plain `Repo` reads.
   Why: an `op.start` built before a result was recorded and pushed after
   the `op.ack` reruns a finished command, and a join that reads around a
   commit misses its `cancel` (`HubOps-bug-stale-start`,
   `-bug-unserialized-read`).
3. The first snapshot for an op sets `confirmed`; from then on `op.start`
   carries `known: true`.
4. A terminal snapshot for an open row is recorded in one commit: `finished`
   (or `closed` if it has `cancel`), `confirmed`, and the signal
   `"op:" <> id`. `op.ack` goes out only after that commit returns.
5. A terminal snapshot for a `finished` or `closed` row gets another
   `op.ack` and changes nothing; a non-terminal one gets `op.cancel`.
6. A snapshot for an op with no row gets `op.ack` if terminal, `op.cancel`
   if not. One for another machine's row is logged and ignored.
7. Every way a call ends without claiming a result (Stop, a failed task, an
   error result, the offline limit) runs `cancel_tx/2` or `abandon_tx/2` in
   the commit that ends it. An open row gets `cancel`, and `op.cancel` is
   sent from inside the commit if the channel is registered then (node rule
   7 makes a rolled-back send safe). A `finished` row is closed and its
   snapshot dropped, keeping the last 8,000 characters of a shell's output
   for the page; `abandon_tx/2` claims it instead and returns the real
   result. Joins resend `op.cancel` for canceled rows, never `op.start`.
   Why: a give-up that raced a reconnect left a command running with its
   call over (`HubOps-bug-abandon-silent`).
8. The commit that records the tool's result closes the row and clears its
   snapshot, so a 5 MB image isn't kept twice.
9. `Machines.start/1` inserts the row only if, in the same commit, the task
   is unfinished and not marked for abort. A step orphaned by a
   Scheduler-only crash is fenced from the task's commits but not this one,
   and could insert an op after Stop that nothing cancels
   (`HubOps-bug-unfenced-insert`).
10. Every error result `Call` returns after deriving the op ID cancels the
    op in its commit, and a raise rescued by `Durable.ToolTask` runs the
    tool's `on_interrupt/2` in the commit that records it. An `execute/2`
    rerun that finds the row skips the machine check and parks, since the
    op may be running whatever the machine looks like now. Why: a row left
    open after the model was told the call failed is started by the next
    join, so a retry runs the command twice (`HubOps-bug-error-skips-cancel`).
11. While a call waits on an online machine, each check (once a minute)
    asks the channel to push its op again. The node answers idempotently.
    This recovers a lost `op.start` or snapshot when the connection never
    dropped (a failed journal write, a channel that crashed on one message).
12. The hub's own machine, `local`, has no node key. When `config :photon,
    :local_node` is true it is known even while disconnected, so a call on
    it parks instead of failing as unknown (at boot the durable harness
    reruns calls before the local node connects).

## Node rules

1. `op.start` with no journal and `known: false` journals a `ready`
   snapshot (fsynced), then starts the op. Nothing runs before that.
2. `op.start` for a journaled op asks for its latest snapshot. If it isn't
   terminal and nothing runs it, the node resumes it from the journal,
   which never reruns a command. Every resume (here, the start-up scan, a
   restart after a clean exit) follows `Ops.add/2` with `Ops.cancel/1` when
   the journal says `cancel`. It never resumes in `canceling`, which kills
   only the snapshot's `pgid` and misses a group known only from `pid`.
3. `op.start` with no journal and `known: true` means the node lost the op.
   It runs nothing and answers, unjournaled, `failed`: "The machine has no
   record of this operation. It may or may not have run."
4. A command spawns only after its `process` checkpoint is journaled, and
   only if the journal doesn't say canceled. If the executor dies during
   that checkpoint, the shell spawns nothing and leaves an `unstarted`
   marker; a resume that finds it, with no process group and no `pid` file,
   starts the command, and without it fails as "outcome unknown". Every
   start removes the marker before its checkpoint.
5. Every snapshot is journaled before it is forwarded.
6. A terminal entry stays until `op.ack`; then the entry, markers, `pid`
   and `exit` go. `out` and `err` stay 7 days, because a truncated result
   names their paths; a daily sweep removes them.
7. `op.cancel` for a journaled unfinished op records `cancel` and tells the
   process. For an op with no journal it journals `canceled` ("Canceled
   before it started") and keeps it until `op.ack`, so a later `op.start`
   gets it back and runs nothing. Why: the hub sends `op.cancel` from a
   commit that may roll back, and the next join then sends `op.start`
   (`HubOps-bug-cancel-unjournaled`). `op.cancel` for a finished op and
   `op.ack` for an unknown or unfinished one are ignored.
8. A failed journal write never runs anything. An unwritable `ready` entry
   is answered with an unjournaled `failed` ("It didn't run."); an
   unwritable `process` checkpoint fails the op unspawned. A later snapshot
   that can't be written is forwarded anyway; a terminal one is held in
   memory until `op.ack` and read in place of the journal, and a `ready`
   entry under it is deleted, since resuming it would start an op the hub
   was told had ended. An unwritable rule 7 `canceled` entry sends nothing;
   the next join resends the cancel. `Connection` and `NodeChannel` don't
   catch errors: a crash closes the socket and the rejoin resends everything.
9. No snapshot is over 6 MB of JSON, under the hub's 8 MB frame limit.
   Bounds count code points and a NUL encodes as 6 bytes, so two
   1,000,000-point streams can reach 12 MB; `Executor.Request.fit/2` cuts
   them by bytes before journaling. Why: the hub closes the socket on an
   oversized frame, the node resends that snapshot on every rejoin, and the
   machine flaps for good while the call waits.
10. A node that stops on purpose (a hub restart stops the local node) kills
    its running commands and says so: the shell writes a `stopped` marker
    before the kill, and recovery reports "photon-node stopped while the
    command was running, so the command was killed." A cancel writes a
    `canceled` marker first, and recovery reports `canceled`. Without them
    the wrapper, outside the killed group, records exit 143 and a killed
    command comes back `completed`. A shell resumed after an abrupt crash
    kills its recorded group on shutdown even before it reattaches.

## What happens when

- Hub restart: a call in `execute/2` reruns (`replay: :safe`) and asks for
  the same op; `resume/2` only reads before its final commit.
- Node restart: running commands are reattached, ones with an `exit` file
  finished, `unstarted` ones started, the rest failed as "outcome unknown".
- Executor crash: op processes keep running; the new executor re-monitors
  them from the journal.
- Stop while the machine is away: the call ends at once; the row keeps
  `cancel`, and the next join sends `op.cancel`.

## Waiting and offline machines

A parked call checks every 60 seconds, re-pushing its op while the machine
is online (hub rule 11). While the machine is offline it counts from
`offline_since`, kept in the parked state so it survives a hub restart, and
gives up after 10 minutes. The count is approximate: a machine that drops
and returns between two checks never counts as offline. Both numbers come
from `config :photon, Photon.MachineTools`.

On giving up, `Wait.offline_message/3` says "the command didn't run" only
when the row was never `pushed` and never `confirmed`. Otherwise it says
the command may have run (and is being stopped, if the machine just came
back), so the model checks before retrying something unsafe to repeat. A
machine the hub doesn't know fails at once, listing the ones it knows.
There is no timeout while the machine is online; Stop ends a command.

## Commands

`shell` keeps unreal-agent's Bash behaviour, run by `Ops.Shell`:

- The machine's default shell runs the command as one `-c` argument, stdin
  from `/dev/null`, stdout and stderr to files, in its own process group.
- When the command exits the group gets SIGTERM, then SIGKILL after five
  seconds, so background children die with it, `nohup` or not. Something
  meant to outlive the call starts in its own group:
  `bash -c 'set -m; nohup CMD >CMD.log 2>&1 &'`. Not `setsid`: its child
  can still be in the old group when that is killed, and macOS lacks it.
- A call holds its conversation until the command exits. Finite long work
  starts detached with its exit code in a file, and Blip checks back with
  `schedule`.
- A command is at most 100,000 bytes: Linux refuses one argument over
  128 KB (`MAX_ARG_STRLEN`), and every snapshot carries the command.
- `directory` is relative to the node's workspace (null is the workspace)
  and is created when missing, before the `process` checkpoint.
- Unlike unreal-agent, recovery reattaches to a command that survived a
  crash instead of failing it, and a deliberate stop kills it.

## Images

`view_image` reads PNG, JPEG, GIF or WebP and returns it base64-encoded,
with dimensions from the header. Unlike unreal-agent it never decodes or
resizes: an image over `max_size` (4,999,000 base64 bytes, about 3.7 MB)
fails with a hint to make a smaller copy. The node refuses a `max_size`
over 5,000,000, since `fit/2` can't cut an image, and the hub checks type
and size again before the model sees it.

## Results and output caps

- Limits count Unicode code points: 40,000 per stream by default, at most
  1,000,000. Longer text keeps half its head and half its tail around a
  marker giving the bytes left out and the full file's path
  (`PhotonCore.Output`).
- The hub bounds each field again at the call's limit plus 1,000 code
  points for the node's marker, so a misbehaving node can't flood the
  model and a well-behaved one isn't cut twice.
- A terminal snapshot whose state doesn't hold what the kind of op the
  hub asked for promises (`PhotonCore.Operation.Result`: strings, integers
  or objects where the hub reads them) is recorded as `failed`, saying the machine sent a result
  the hub can't read, and acknowledged like any result.
- A failed or canceled op is an ok tool result starting `Error:`, so its
  details reach the UI. A canceled shell carries what it printed.
- Live output is sampled once a second, at most 64 KB per stream, and
  never stored. The page keeps the last 8,000 characters per call.
- Older runs' results are shortened in context (`Photon.Durable.Context`),
  pointing at the full files through the result's `full_output` detail.
