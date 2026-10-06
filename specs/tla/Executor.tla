------------------------------- MODULE Executor -------------------------------
(***************************************************************************)
(* The node's executor for the hub's operations (apps/node/lib/photon_node/ *)
(* executor.ex, its rules in executor/rules.ex and its journal in          *)
(* executor/journal.ex), the shell operation processes it owns            *)
(* (ops.ex, ops/shell.ex) and the OS commands they run, with a stand-in    *)
(* for the hub that follows the hub rules of section 2.3 of                *)
(* docs/plans/step-1-machine-tools.md. Faults: executor crashes at any    *)
(* point inside any of its handlers, operation process crashes, abrupt    *)
(* node crashes (commands survive), node stops (a shell kills its command *)
(* and leaves the `stopped` marker, or leaves the `unstarted` marker when  *)
(* it was waiting to start one), dropped connections, and commands that   *)
(* leave background children or never exit. Executor.md has the          *)
(* mapping to the code, the results and the findings.                     *)
(*                                                                         *)
(* HubOps.tla models the protocol end to end with the executor as one     *)
(* atomic party; this spec opens the executor up and leaves the hub        *)
(* simple.                                                                 *)
(*                                                                         *)
(* An executor handler is written as a pure function that returns its     *)
(* effects in order (journal writes, forwards to the hub, Ops.add,         *)
(* Ops.cancel, the reply to an operation's call). A step either applies   *)
(* all of them, or crashes after any prefix: the journal is fsynced at     *)
(* each write, so a crash keeps exactly the writes before it.             *)
(*                                                                         *)
(* Bugs puts back defects the code fixed, one switch each (Executor.md):  *)
(*   "double_exec"        the command spawns before its `process`         *)
(*                        checkpoint is journaled (Coordinator F3)        *)
(*   "cancel_before_pid"  a cancel that comes before the pid line doesn't  *)
(*                        kill the command once the pid is known (F8)     *)
(*   "unmonitored"        the executor doesn't monitor its operations (F9) *)
(*   "poll_order"         a reattached shell checks its group before the  *)
(*                        exit file (F11)                                  *)
(*   "no_pid_file"        the wrapper writes no pid file (K1)             *)
(*   "no_stopped_marker"  a stopping shell kills its command without the  *)
(*                        `stopped` marker (node rule 10)                  *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
  NOps,           \* operations (tool calls), each with its own op ID
  MaxExecCrash,   \* executor crashes (inside a handler or between them)
  MaxOpCrash,     \* operation process crashes
  MaxNodeCrash,   \* abrupt node crashes: every BEAM process dies, commands survive
  MaxNodeStop,    \* node stops: shells kill their commands on the way down
  MaxDisconnect,  \* dropped websockets
  MaxCancel,      \* the hub cancels an op (Stop, an error, the offline limit)
  MaxRepush,      \* extra op.start pushes for an open row (hub rule 11)
  BgChildren,     \* commands may leave background children in their group
  Bugs            \* defects to put back (see above)

BugNames == {"double_exec", "cancel_before_pid", "unmonitored", "poll_order",
             "no_pid_file", "no_stopped_marker"}
ASSUME Bugs \subseteq BugNames
ASSUME NOps \in 1..2

Bug(b) == b \in Bugs

VARIABLES
  jr,      \* the journal: per op, its entry (st "none" = no op.json)
  es,      \* the executor process: "up", "scan" (handle_continue pending),
           \*   "down" (crashed, not restarted yet) or "off" (node down)
  monCur,  \* per op: the executor monitors the op's live process
  downq,   \* per op: :DOWN messages in the executor's mailbox, oldest first
  rst,     \* per op: restarted once after a clean exit (Rules.down/3)
  p,       \* per op: its operation process (Ops.Shell)
  os,      \* per op: the command, its group, and its files
  conn,    \* the node's Connection joined to the hub: "up" or "down"
  h2n,     \* hub -> node messages in flight
  n2h,     \* node -> hub snapshots in flight
  hrow,    \* per op, the hub's row: "none", "open" or "done" (result recorded)
  hcx,     \* per op: the hub canceled it
  hconf,   \* per op: the hub has seen a snapshot (op.start's `known`)
  hres,    \* per op: the result the hub recorded
  nodeUp,  \* the node's VM runs
  cnt      \* fault and event budgets

exVars  == <<jr, es, monCur, downq, rst>>
netVars == <<conn, h2n, n2h>>
hubVars == <<hrow, hcx, hconf, hres>>
vars    == <<jr, es, monCur, downq, rst, p, os, conn, h2n, n2h,
             hrow, hcx, hconf, hres, nodeUp, cnt>>

Ops  == 1..NOps
Term == {"completed", "failed", "canceled"}   \* Operation.terminal?/1
\* Snapshots, reduced to their status: ready; awaiting/process without a
\* pgid ("proc0") and with one ("proc1"); awaiting/read; and the terminal
\* ones. "lost" is Request.lost/2, which is never journaled.
Live == {"ready", "proc0", "proc1", "read"}

NoEntry == [st |-> "none", cx |-> FALSE]

(***************************************************************************)
(* Operation processes and commands.                                        *)
(*   proc: "none"; "init" (handle_continue pending); "ck" (in its           *)
(*         `process` checkpoint call, Owner.checkpoint/2); "rep" (in a      *)
(*         report call, Owner.report/2, then going on at `nxt`); and the    *)
(*         states where it waits for messages: "spawning" (port open, no    *)
(*         pid line yet), "running" and "polling" (reattached, port nil)    *)
(*   snap: the snapshot it holds (what :resend reports)                     *)
(*   ans:  the answer to its call: ok, cancel, ignored, or exit (the        *)
(*         executor died: checkpoint/2 returns :ignored, report/2 :down)    *)
(*   cancel, resend: a :cancel or :resend message waiting                   *)
(*   canceled: Shell's `canceled` flag; port: the wrapper's port is open    *)
(***************************************************************************)
NoProc == [proc |-> "none", init |-> "none", snap |-> "none", call |-> "none",
           ans |-> "none", nxt |-> "none", cancel |-> FALSE, canceled |-> FALSE,
           resend |-> FALSE, port |-> FALSE]
NewProc(st) == [NoProc EXCEPT !.proc = "init", !.init = st, !.snap = st]

\* The command. exit: the wrapper's exit file; pidf: its pid file; stopped:
\* the `stopped` marker; unst: the `unstarted` marker (a start that never
\* spawned); self: the command exited on its own (a ghost).
NoOS == [cmd |-> "none", bg |-> FALSE, exit |-> FALSE, execs |-> 0,
         pidf |-> FALSE, stopped |-> FALSE, unst |-> FALSE, self |-> FALSE]

Msg(k, c, kn) == [k |-> k, c |-> c, kn |-> kn]

(***************************************************************************)
(* Executor handlers: pure functions of the current state that return     *)
(* their effects in order.                                                 *)
(***************************************************************************)
Fx(e, c, st, cx) == [e |-> e, c |-> c, st |-> st, cx |-> cx]
FxJw(c, st, cx) == Fx("jw", c, st, cx)       \* Journal.write/3 (fsynced)
FxJf(c)         == Fx("jf", c, "none", FALSE) \* Journal.forget/2
FxFwd(c, st)    == Fx("fwd", c, st, FALSE)    \* Link.snapshot/1
FxAdd(c, st)    == Fx("add", c, st, FALSE)    \* Ops.add/2, then watch/3
FxCx(c)         == Fx("cxp", c, "none", FALSE) \* Ops.cancel/1
FxReply(c, a)   == Fx("reply", c, a, FALSE)   \* the reply to a call
FxRst(c)        == Fx("rst", c, "none", FALSE) \* `restarted` gains the op

Running(c) == p[c].proc # "none"               \* Ops.running?/1

\* revive/3: Ops.add/2 (start the op from its entry, or ask the process
\* that runs it to resend), monitor it, and Ops.cancel/1 when cancel?.
Revive(c, st, cx) == <<FxAdd(c, st)>> \o (IF cx THEN <<FxCx(c)>> ELSE <<>>)

\* op.start: start_op/2 with Rules.on_start/3.
HStart(c, known) ==
  LET e == jr[c] IN
  IF e.st = "none"
  THEN IF ~known
       THEN \* :run -> run_journaled/2: nothing runs before `ready` is on disk
            <<FxJw(c, "ready", FALSE), FxFwd(c, "ready")>> \o Revive(c, "ready", FALSE)
       ELSE <<FxFwd(c, "lost")>>                         \* :lost
  ELSE IF e.st \in Term THEN <<FxFwd(c, e.st)>>         \* {:resend, false}
  ELSE IF Running(c)
  THEN <<FxFwd(c, e.st)>> \o (IF e.cx THEN <<FxCx(c)>> ELSE <<>>)   \* {:resend, cx}
  ELSE <<FxFwd(c, e.st)>> \o Revive(c, e.st, e.cx)                  \* {:resume, cx}

\* op.cancel: cancel_op/2 (node rule 7).
HCancel(c) ==
  LET e == jr[c] IN
  IF e.st = "none"
  THEN <<FxJw(c, "canceled", TRUE), FxFwd(c, "canceled")>>   \* cancel_unstarted/2
  ELSE IF e.st \in Term THEN <<>>
  ELSE <<FxJw(c, e.st, TRUE)>> \o                             \* cancel_unfinished/2
       (IF Running(c) THEN <<FxCx(c)>> ELSE Revive(c, e.st, TRUE))

\* op.ack: ack_op/2 (node rule 6).
HAck(c) == IF jr[c].st \in Term THEN <<FxJf(c)>> ELSE <<>>

\* checkpoint_op/2 (node rule 4): journaled, forwarded, then :ok.
HCheckpoint(c) ==
  LET e == jr[c] IN
  IF e.st = "none" \/ e.st \in Term THEN <<FxReply(c, "ignored")>>
  ELSE IF e.cx THEN <<FxReply(c, "cancel")>>
  ELSE <<FxJw(c, "proc0", FALSE), FxFwd(c, "proc0"), FxReply(c, "ok")>>

\* report_op/2 (node rule 5): a snapshot after a finished one changes nothing.
HReport(c) ==
  LET e == jr[c] IN
  IF e.st = "none" \/ e.st \in Term THEN <<FxReply(c, "ok")>>
  ELSE <<FxJw(c, p[c].call, e.cx), FxFwd(c, p[c].call), FxReply(c, "ok")>>

\* down/3 and exited/3 with Rules.down/3, for the oldest :DOWN. An exit of
\* a process that has been replaced (the op is still monitored) is ignored.
HDown(c) ==
  LET r == Head(downq[c])
      e == jr[c]
  IN IF monCur[c] \/ Len(downq[c]) > 1 THEN <<>>
     ELSE IF e.st = "none" \/ e.st \in Term THEN <<>>              \* :ignore
     ELSE IF r = "normal" /\ ~rst[c]
     THEN <<FxRst(c)>> \o Revive(c, e.st, e.cx)                     \* {:restart, cx}
     ELSE <<FxJw(c, "failed", e.cx), FxFwd(c, "failed")>>           \* {:fail, _}

\* handle_continue(:scan) with Rules.on_scan/2, in ID order: every
\* unfinished op is revived (a running one resends, a missing one resumes).
RECURSIVE ScanFrom(_)
ScanFrom(c) ==
  IF c > NOps THEN <<>>
  ELSE (IF jr[c].st \in Live THEN Revive(c, jr[c].st, jr[c].cx) ELSE <<>>) \o ScanFrom(c + 1)

(***************************************************************************)
(* Applying effects.                                                        *)
(***************************************************************************)
World == [jr |-> jr, n2h |-> n2h, p |-> p, monCur |-> monCur, rst |-> rst]

\* Evaluate x once and hand the value to F. TLC evaluates operator arguments
\* and LET definitions lazily and doesn't cache them while it checks ENABLED
\* and temporal formulas, so without this the fold below costs exponential
\* time in liveness checking (as Coordinator.tla found).
Strict(x, F(_)) == CHOOSE r \in {F(v) : v \in {x}} : TRUE

Eff(W0, f) == Strict(W0, LAMBDA W :
  CASE f.e = "jw"  -> [W EXCEPT !.jr[f.c] = [st |-> f.st, cx |-> f.cx]]
    [] f.e = "jf"  -> [W EXCEPT !.jr[f.c] = NoEntry, !.rst[f.c] = FALSE]
    [] f.e = "fwd" -> \* the Connection pushes it if joined, else drops it
                      IF conn = "up" THEN [W EXCEPT !.n2h = Append(@, [c |-> f.c, st |-> f.st])]
                      ELSE W
    [] f.e = "add" -> \* a running process is asked to resend; else one starts
                      [W EXCEPT !.p[f.c] = IF W.p[f.c].proc # "none"
                                           THEN [W.p[f.c] EXCEPT !.resend = TRUE]
                                           ELSE NewProc(f.st),
                                !.monCur[f.c] = ~Bug("unmonitored")]
    [] f.e = "cxp" -> IF W.p[f.c].proc # "none" THEN [W EXCEPT !.p[f.c].cancel = TRUE] ELSE W
    [] f.e = "reply" -> [W EXCEPT !.p[f.c].ans = f.st]
    [] OTHER       -> [W EXCEPT !.rst[f.c] = TRUE])

RECURSIVE Fold(_, _, _)
Fold(W0, fx, i) == Strict(W0, LAMBDA W :
  IF i > Len(fx) THEN W ELSE Fold(Eff(W, fx[i]), fx, i + 1))

AllOps(v) == [c \in Ops |-> v]

\* A handler that runs to its end.
Commit(fx, h2n2, downq2, es2) ==
  \E W \in {Fold(World, fx, 1)} :
  /\ jr' = W.jr /\ n2h' = W.n2h /\ p' = W.p /\ monCur' = W.monCur /\ rst' = W.rst
  /\ h2n' = h2n2 /\ downq' = downq2 /\ es' = es2
  /\ UNCHANGED <<os, conn, hubVars, nodeUp, cnt>>

\* The executor dies with the world W. Its monitors, restart counts and
\* mailbox are gone. A call waiting on it returns (checkpoint/2 :ignored,
\* report/2 :down). PhotonNode is :rest_for_one, so the Connection after
\* it restarts too: the socket closes and messages in flight are lost.
CrashAfter(W) ==
  /\ jr' = W.jr
  /\ p' = [c \in Ops |-> IF W.p[c].proc \in {"ck", "rep"} /\ W.p[c].ans = "none"
                         THEN [W.p[c] EXCEPT !.ans = "exit"] ELSE W.p[c]]
  /\ monCur' = AllOps(FALSE) /\ downq' = AllOps(<<>>) /\ rst' = AllOps(FALSE)
  /\ es' = "down" /\ conn' = "down" /\ h2n' = <<>> /\ n2h' = <<>>
  /\ cnt' = [cnt EXCEPT !.exc = @ + 1]
  /\ UNCHANGED <<os, hubVars, nodeUp>>

\* The node's VM dies abruptly with the world W: every process is gone, the
\* journal and the commands stay.
NodeDownAfter(W) ==
  /\ jr' = W.jr
  /\ p' = AllOps(NoProc)
  /\ monCur' = AllOps(FALSE) /\ downq' = AllOps(<<>>) /\ rst' = AllOps(FALSE)
  /\ es' = "off" /\ nodeUp' = FALSE
  /\ conn' = "down" /\ h2n' = <<>> /\ n2h' = <<>>
  /\ cnt' = [cnt EXCEPT !.node = @ + 1]
  /\ UNCHANGED <<os, hubVars>>

Modes == {"ok", "crash", "node"}

ExecRun(fx0, h2n2, downq2, es2, mode) ==
  \E fx \in {fx0} :
  CASE mode = "ok"    -> Commit(fx, h2n2, downq2, es2)
    [] mode = "crash" -> /\ cnt.exc < MaxExecCrash
                         /\ \E k \in 0..Len(fx) : \E W \in {Fold(World, SubSeq(fx, 1, k), 1)} :
                              CrashAfter(W)
    [] OTHER          -> /\ cnt.node < MaxNodeCrash
                         /\ \E k \in 0..Len(fx) : \E W \in {Fold(World, SubSeq(fx, 1, k), 1)} :
                              NodeDownAfter(W)

(***************************************************************************)
(* Executor steps.                                                          *)
(***************************************************************************)
\* The Connection hands a hub message to the executor (a call).
NodeRecv(mode) ==
  /\ nodeUp /\ es = "up" /\ conn = "up" /\ h2n # <<>>
  /\ LET m == Head(h2n)
         fx == CASE m.k = "start"  -> HStart(m.c, m.kn)
                 [] m.k = "cancel" -> HCancel(m.c)
                 [] OTHER          -> HAck(m.c)
     IN ExecRun(fx, Tail(h2n), downq, es, mode)

ExecCheckpoint(c, mode) ==
  /\ nodeUp /\ es = "up" /\ p[c].proc = "ck" /\ p[c].ans = "none"
  /\ ExecRun(HCheckpoint(c), h2n, downq, es, mode)

ExecReport(c, mode) ==
  /\ nodeUp /\ es = "up" /\ p[c].proc = "rep" /\ p[c].ans = "none"
  /\ ExecRun(HReport(c), h2n, downq, es, mode)

ExecDown(c, mode) ==
  /\ nodeUp /\ es = "up" /\ downq[c] # <<>>
  /\ ExecRun(HDown(c), h2n, [downq EXCEPT ![c] = Tail(@)], es, mode)

ScanStep(mode) ==
  /\ nodeUp /\ es = "scan"
  /\ ExecRun(ScanFrom(1), h2n, downq, "up", mode)

\* A crash between handlers.
ExecCrash ==
  /\ nodeUp /\ es = "up" /\ cnt.exc < MaxExecCrash
  /\ CrashAfter(World)

\* The supervisor restarts the executor (init/1, then the scan) and the
\* Connection after it.
ExecRestart ==
  /\ nodeUp /\ es = "down"
  /\ es' = "scan"
  /\ UNCHANGED <<jr, monCur, downq, rst, p, os, netVars, hubVars, nodeUp, cnt>>

\* A call made while the executor isn't registered exits at once (:noproc).
CallNoproc(c) ==
  /\ nodeUp /\ es = "down" /\ p[c].proc \in {"ck", "rep"} /\ p[c].ans = "none"
  /\ p' = [p EXCEPT ![c].ans = "exit"]
  /\ UNCHANGED <<exVars, os, netVars, hubVars, nodeUp, cnt>>

(***************************************************************************)
(* Operation processes (Ops.Shell) and commands.                            *)
(***************************************************************************)
ProcUnch == UNCHANGED <<jr, es, rst, netVars, hubVars, nodeUp, cnt>>

Become(c, q2, o2) ==
  /\ p' = [p EXCEPT ![c] = q2] /\ os' = [os EXCEPT ![c] = o2]
  /\ UNCHANGED <<monCur, downq>> /\ ProcUnch

\* The process exits (reason r); its monitor turns that into a :DOWN.
Gone(c, o2, r) ==
  /\ p' = [p EXCEPT ![c] = NoProc] /\ os' = [os EXCEPT ![c] = o2]
  /\ IF monCur[c]
     THEN /\ downq' = [downq EXCEPT ![c] = Append(@, r)]
          /\ monCur' = [monCur EXCEPT ![c] = FALSE]
     ELSE UNCHANGED <<downq, monCur>>
Exit(c, o2, r) == Gone(c, o2, r) /\ ProcUnch

\* checkpoint/3: advance the snapshot and report it (a call), then go on.
Report(q, st, nxt) == [q EXCEPT !.proc = "rep", !.call = st, !.snap = st,
                                !.nxt = nxt, !.ans = "none"]

\* The wrapper starts the command and writes its pid file.
Spawn(o) == [cmd |-> "running", bg |-> FALSE, exit |-> FALSE, execs |-> o.execs + 1,
             pidf |-> ~Bug("no_pid_file"), stopped |-> FALSE, unst |-> FALSE,
             self |-> FALSE]

\* kill_group/3: the whole group goes. The wrapper records the killed
\* command's exit status (143).
KillOS(o) == [o EXCEPT !.cmd = IF o.cmd = "running" THEN "exited" ELSE @,
                       !.exit = @ \/ o.cmd = "running", !.bg = FALSE]
KillIf(o, pgid) == IF pgid THEN KillOS(o) ELSE o

\* recorded_pgid/1: from the snapshot, else from the pid file.
PgidKnown(q, o) == q.snap = "proc1" \/ o.pidf

\* prepare/1: remove the leftover files (the `unstarted` marker among them),
\* then ask for the `process` checkpoint.
Prepare(c, q, o) ==
  Become(c, [q EXCEPT !.proc = "ck", !.call = "ck", !.ans = "none"], [o EXCEPT !.unst = FALSE])

\* recover/1 after any pid-file checkpoint, then reattach/2.
RecoverTo(c, q, o, pgid) ==
  IF o.stopped THEN Become(c, Report(q, "failed", "exit"), KillIf(o, pgid))  \* node rule 10
  ELSE IF ~pgid /\ o.unst THEN Prepare(c, q, o)           \* never started (node rule 4)
  ELSE IF ~pgid THEN Become(c, Report(q, "failed", "exit"), o)       \* outcome unknown
  ELSE IF o.exit THEN Become(c, Report(q, "read", "complete"), KillOS(o))
  ELSE IF o.cmd = "running" \/ o.bg THEN Become(c, [q EXCEPT !.proc = "polling"], o)
  ELSE Become(c, Report(q, "failed", "exit"), o)                      \* interrupted

\* handle_continue(:start)
OpInit(c) ==
  /\ nodeUp /\ p[c].proc = "init"
  /\ LET q == p[c]
         o == os[c]
     IN CASE q.init = "ready" ->
               IF Bug("double_exec")
               THEN Become(c, Report([q EXCEPT !.port = TRUE], "proc0", "spawning"), Spawn(o))
               ELSE Prepare(c, q, o)
          [] q.init = "proc0" /\ o.pidf -> Become(c, Report(q, "proc1", "recover"), o)
          [] q.init = "proc1" \/ (q.init = "proc0" /\ ~o.pidf) ->
               RecoverTo(c, q, o, q.init = "proc1")
          [] q.init = "read" -> Become(c, Report(q, "completed", "exit"), o)    \* finish/2
          [] OTHER -> Exit(c, o, "normal")

\* start_when_confirmed/2: the checkpoint call returned.
OpCkDone(c) ==
  /\ nodeUp /\ p[c].proc = "ck" /\ p[c].ans # "none"
  /\ LET q == p[c]
         o == os[c]
     IN CASE q.ans = "ok" ->
               Become(c, [q EXCEPT !.proc = "spawning", !.snap = "proc0", !.port = TRUE,
                                   !.call = "none", !.ans = "none"], Spawn(o))
          [] q.ans = "cancel" -> Become(c, Report(q, "canceled", "exit"), o)
          [] OTHER ->                     \* :ignored: the marker, then stop, run nothing
               Exit(c, [o EXCEPT !.unst = TRUE], "normal")

\* A report call returned (:ok, or :down if the executor died); go on.
OpReturn(c) ==
  /\ nodeUp /\ p[c].proc = "rep" /\ p[c].ans # "none"
  /\ LET q == [p[c] EXCEPT !.call = "none", !.ans = "none"]
         o == os[c]
     IN CASE q.nxt = "exit" -> Exit(c, o, "normal")
          [] q.nxt = "complete" -> Become(c, Report(q, "completed", "exit"), o)
          [] q.nxt = "runcheck" ->                       \* kill_if_canceled/2
               Become(c, [q EXCEPT !.proc = "running"],
                      IF q.canceled /\ ~Bug("cancel_before_pid") THEN KillOS(o) ELSE o)
          [] q.nxt = "recover" -> RecoverTo(c, q, o, TRUE)
          [] OTHER -> Become(c, [q EXCEPT !.proc = q.nxt], o)

\* The wrapper prints "pid N".
PidLine(c) ==
  /\ nodeUp /\ p[c].proc = "spawning"
  /\ Become(c, Report(p[c], "proc1", "runcheck"), os[c])

\* {:exit_status, _}: kill what is left of the group, then exited/2.
PortExit(c) ==
  /\ nodeUp /\ p[c].proc = "running" /\ os[c].cmd = "exited"
  /\ LET q == [p[c] EXCEPT !.port = FALSE] IN
     Become(c, IF q.canceled THEN Report(q, "canceled", "exit") ELSE Report(q, "read", "complete"),
            [os[c] EXCEPT !.bg = FALSE])

\* handle_info(:cancel, _)
OpCancel(c) ==
  /\ nodeUp /\ p[c].cancel /\ p[c].proc \in {"spawning", "running", "polling"}
  /\ LET q == [p[c] EXCEPT !.cancel = FALSE]
         o == os[c]
     IN CASE q.proc = "spawning" -> Become(c, [q EXCEPT !.canceled = TRUE], o)  \* kill_group(nil)
          [] q.proc = "running"  -> Become(c, [q EXCEPT !.canceled = TRUE], KillOS(o))
          [] OTHER -> Become(c, Report(q, "canceled", "exit"), KillOS(o))      \* port nil: cancel/1

\* handle_info(:resend, _)
OpResend(c) ==
  /\ nodeUp /\ p[c].resend /\ p[c].proc \in {"spawning", "running", "polling"}
  /\ Become(c, Report([p[c] EXCEPT !.resend = FALSE], p[c].snap, p[c].proc), os[c])

\* :poll after reattaching (poll_recovered/1): the exit file first, then
\* whether the group still lives.
Poll(c) ==
  /\ nodeUp /\ p[c].proc = "polling"
  /\ LET q == p[c]
         o == os[c]
         alive == o.cmd = "running" \/ o.bg
     IN /\ IF Bug("poll_order") THEN ~alive ELSE o.exit \/ ~alive
        /\ IF o.exit THEN Become(c, Report(q, "read", "complete"), KillOS(o))
           ELSE Become(c, Report(q, "failed", "exit"), o)

\* A shell that reattached to its command and still waits for it (the
\* `reattached` flag with an `awaiting` snapshot): polling, or reporting a
\* resend on the way back to polling.
Reattached(q) == q.proc = "polling" \/ (q.proc = "rep" /\ q.nxt = "polling")

Marked(o) == [o EXCEPT !.stopped = IF Bug("no_stopped_marker") THEN @ ELSE TRUE]

\* terminate/2: the stopped marker, then the kill, when the port is open or
\* the shell reattached (its snapshot has the pgid).
Terminated(q, o) ==
  IF q.port THEN Marked(KillIf(o, PgidKnown(q, o)))
  ELSE IF Reattached(q) THEN Marked(KillOS(o))
  ELSE o

\* An operation process crashes (a bug in its own code, so never while it
\* waits in a call). terminate/2 runs; the monitor reports the crash.
OpCrash(c) ==
  /\ nodeUp /\ cnt.opc < MaxOpCrash
  /\ p[c].proc \in {"init", "spawning", "running", "polling"}
  /\ Gone(c, Terminated(p[c], os[c]), "crash")
  /\ cnt' = [cnt EXCEPT !.opc = @ + 1]
  /\ UNCHANGED <<jr, es, rst, netVars, hubVars, nodeUp>>

\* The command exits on its own; the wrapper writes the exit file.
CmdExit(c) ==
  /\ os[c].cmd = "running"
  /\ \E b \in (IF BgChildren THEN BOOLEAN ELSE {FALSE}) :
       os' = [os EXCEPT ![c].cmd = "exited", ![c].exit = TRUE, ![c].self = TRUE,
                        ![c].bg = @ \/ b]
  /\ UNCHANGED <<exVars, p, netVars, hubVars, nodeUp, cnt>>

\* A background child left in the group exits (a daemon may never).
BgExit(c) ==
  /\ os[c].bg
  /\ os' = [os EXCEPT ![c].bg = FALSE]
  /\ UNCHANGED <<exVars, p, netVars, hubVars, nodeUp, cnt>>

(***************************************************************************)
(* The node's VM.                                                           *)
(***************************************************************************)
NodeCrash ==
  /\ nodeUp /\ cnt.node < MaxNodeCrash
  /\ NodeDownAfter(World)

\* A stop on purpose: shutdown runs in reverse start order, so the
\* Connection and the executor stop first, then every shell's terminate/2.
\* A shell still waiting in its checkpoint call gets :ignored when the
\* executor stops, and writes the `unstarted` marker as it stops.
Stopped(q, o) ==
  IF q.proc = "ck" /\ q.ans \in {"none", "ignored", "exit"} THEN [o EXCEPT !.unst = TRUE]
  ELSE Terminated(q, o)

NodeStop ==
  /\ nodeUp /\ cnt.stop < MaxNodeStop
  /\ os' = [c \in Ops |-> Stopped(p[c], os[c])]
  /\ p' = AllOps(NoProc)
  /\ monCur' = AllOps(FALSE) /\ downq' = AllOps(<<>>) /\ rst' = AllOps(FALSE)
  /\ es' = "off" /\ nodeUp' = FALSE
  /\ conn' = "down" /\ h2n' = <<>> /\ n2h' = <<>>
  /\ cnt' = [cnt EXCEPT !.stop = @ + 1]
  /\ UNCHANGED <<jr, hubVars>>

\* The node starts again: PhotonNode.init/1, then the executor's scan.
NodeBoot ==
  /\ ~nodeUp
  /\ nodeUp' = TRUE /\ es' = "scan"
  /\ UNCHANGED <<jr, monCur, downq, rst, p, os, netVars, hubVars, cnt>>

(***************************************************************************)
(* The websocket and the hub.                                               *)
(***************************************************************************)
RECURSIVE SnapsFrom(_)
\* Executor.snapshots/0: every journaled snapshot, in ID order.
SnapsFrom(c) ==
  IF c > NOps THEN <<>>
  ELSE (IF jr[c].st # "none" THEN <<[c |-> c, st |-> jr[c].st]>> ELSE <<>>) \o SnapsFrom(c + 1)

RECURSIVE JoinFrom(_)
\* Machines.joined/1: op.cancel for a canceled open row, op.start otherwise.
JoinFrom(c) ==
  IF c > NOps THEN <<>>
  ELSE (IF hrow[c] = "open"
        THEN <<IF hcx[c] THEN Msg("cancel", c, FALSE) ELSE Msg("start", c, hconf[c])>>
        ELSE <<>>) \o JoinFrom(c + 1)

\* The Connection joins: the node pushes its journal's snapshots
\* (handle_join/3) and the hub pushes what its open rows call for.
Join ==
  /\ nodeUp /\ es = "up" /\ conn = "down"
  /\ conn' = "up" /\ n2h' = SnapsFrom(1) /\ h2n' = JoinFrom(1)
  /\ UNCHANGED <<exVars, p, os, hubVars, nodeUp, cnt>>

Disconnect ==
  /\ conn = "up" /\ cnt.disc < MaxDisconnect
  /\ conn' = "down" /\ h2n' = <<>> /\ n2h' = <<>>
  /\ cnt' = [cnt EXCEPT !.disc = @ + 1]
  /\ UNCHANGED <<exVars, p, os, hubVars, nodeUp>>

Push(m) == IF conn = "up" THEN h2n' = Append(h2n, m) ELSE UNCHANGED h2n

\* A tool call starts an op: its row, and op.start if the node is joined.
HubStart(c) ==
  /\ hrow[c] = "none"
  /\ hrow' = [hrow EXCEPT ![c] = "open"]
  /\ Push(Msg("start", c, FALSE))
  /\ UNCHANGED <<exVars, p, os, conn, n2h, hcx, hconf, hres, nodeUp, cnt>>

\* An online recheck pushes op.start again (hub rule 11).
HubRepush(c) ==
  /\ hrow[c] = "open" /\ ~hcx[c] /\ conn = "up" /\ cnt.rep < MaxRepush
  /\ h2n' = Append(h2n, Msg("start", c, hconf[c]))
  /\ cnt' = [cnt EXCEPT !.rep = @ + 1]
  /\ UNCHANGED <<exVars, p, os, conn, n2h, hubVars, nodeUp>>

\* The call ends another way (hub rule 7): `cancel` on the row, and
\* op.cancel if the node is joined.
HubCancel(c) ==
  /\ hrow[c] = "open" /\ ~hcx[c] /\ cnt.cx < MaxCancel
  /\ hcx' = [hcx EXCEPT ![c] = TRUE]
  /\ Push(Msg("cancel", c, FALSE))
  /\ cnt' = [cnt EXCEPT !.cx = @ + 1]
  /\ UNCHANGED <<exVars, p, os, conn, n2h, hrow, hconf, hres, nodeUp>>

\* op.snapshot (hub rules 3 to 6).
HubRecv ==
  /\ conn = "up" /\ n2h # <<>>
  /\ LET m == Head(n2h)
         c == m.c
         fin == m.st \in Term \cup {"lost"}
     IN /\ n2h' = Tail(n2h)
        /\ IF fin /\ hrow[c] = "open"
           THEN /\ hrow' = [hrow EXCEPT ![c] = "done"]
                /\ hres' = [hres EXCEPT ![c] = m.st]
                /\ hconf' = [hconf EXCEPT ![c] = TRUE]
                /\ h2n' = Append(h2n, Msg("ack", c, FALSE))
           ELSE /\ UNCHANGED <<hrow, hres>>
                /\ hconf' = IF hrow[c] = "open" THEN [hconf EXCEPT ![c] = TRUE] ELSE hconf
                /\ h2n' = IF fin THEN Append(h2n, Msg("ack", c, FALSE))
                          ELSE IF hrow[c] = "open" THEN h2n
                          ELSE Append(h2n, Msg("cancel", c, FALSE))
  /\ UNCHANGED <<exVars, p, os, conn, hcx, nodeUp, cnt>>

(***************************************************************************)
(* Specification.                                                           *)
(***************************************************************************)
Init ==
  /\ jr = AllOps(NoEntry) /\ es = "up"
  /\ monCur = AllOps(FALSE) /\ downq = AllOps(<<>>) /\ rst = AllOps(FALSE)
  /\ p = AllOps(NoProc) /\ os = AllOps(NoOS)
  /\ conn = "up" /\ h2n = <<>> /\ n2h = <<>>
  /\ hrow = AllOps("none") /\ hcx = AllOps(FALSE) /\ hconf = AllOps(FALSE)
  /\ hres = AllOps("none")
  /\ nodeUp = TRUE
  /\ cnt = [exc |-> 0, opc |-> 0, node |-> 0, stop |-> 0, disc |-> 0, cx |-> 0, rep |-> 0]

ExecNext ==
  \E mode \in Modes :
    \/ NodeRecv(mode) \/ ScanStep(mode)
    \/ \E c \in Ops : ExecCheckpoint(c, mode) \/ ExecReport(c, mode) \/ ExecDown(c, mode)

OpNext ==
  \E c \in Ops :
    \/ OpInit(c) \/ OpCkDone(c) \/ OpReturn(c) \/ PidLine(c) \/ PortExit(c)
    \/ OpCancel(c) \/ OpResend(c) \/ Poll(c) \/ OpCrash(c) \/ CmdExit(c) \/ BgExit(c)
    \/ CallNoproc(c)

EnvNext ==
  \/ \E c \in Ops : HubStart(c) \/ HubRepush(c) \/ HubCancel(c)
  \/ HubRecv \/ Join \/ Disconnect
  \/ ExecCrash \/ ExecRestart \/ NodeCrash \/ NodeStop \/ NodeBoot

Next == ExecNext \/ OpNext \/ EnvNext

\* What the code guarantees: the executor handles what it is sent, the
\* supervisor restarts it, operation processes make progress, the node
\* boots again, the Connection rejoins, and the hub handles what arrives.
\* Nothing is fair about tool calls, Stops, re-pushes or faults.
SysNext ==
  \/ NodeRecv("ok") \/ ScanStep("ok")
  \/ \E c \in Ops : \/ ExecCheckpoint(c, "ok") \/ ExecReport(c, "ok") \/ ExecDown(c, "ok")
                    \/ CallNoproc(c) \/ OpInit(c) \/ OpCkDone(c) \/ OpReturn(c)
                    \/ PidLine(c) \/ PortExit(c) \/ OpCancel(c) \/ OpResend(c) \/ Poll(c)
  \/ ExecRestart \/ NodeBoot \/ Join \/ HubRecv

\* Commands eventually exit on their own (background children need not).
SysNextExit == SysNext \/ \E c \in Ops : CmdExit(c)

\* Per-action weak fairness, as the code provides.
FairnessFine ==
  /\ WF_vars(NodeRecv("ok")) /\ WF_vars(ScanStep("ok"))
  /\ \A c \in Ops : WF_vars(ExecCheckpoint(c, "ok")) /\ WF_vars(ExecReport(c, "ok"))
                    /\ WF_vars(ExecDown(c, "ok")) /\ WF_vars(CallNoproc(c))
  /\ \A c \in Ops : /\ WF_vars(OpInit(c)) /\ WF_vars(OpCkDone(c)) /\ WF_vars(OpReturn(c))
                    /\ WF_vars(PidLine(c)) /\ WF_vars(PortExit(c)) /\ WF_vars(OpCancel(c))
                    /\ WF_vars(OpResend(c)) /\ WF_vars(Poll(c))
  /\ WF_vars(ExecRestart) /\ WF_vars(NodeBoot) /\ WF_vars(Join) /\ WF_vars(HubRecv)

\* One weak-fairness condition on all system actions, as in Durable.tla.
\* It is weaker than FairnessFine (it only rules out stopping while a system
\* action is enabled), so a liveness property that holds under it holds
\* under FairnessFine too, and TLC checks it far faster: it evaluates one
\* ENABLED instead of about twenty. System actions alone can't loop (each
\* one moves an op, a message or a process forward), so a behavior that
\* keeps taking system steps does reach the step a finer condition asks for.
Spec == Init /\ [][Next]_vars /\ WF_vars(SysNextExit)
\* Commands may run forever (servers, sleep 1e9): only a cancel ends them.
SpecUnboundedCommands == Init /\ [][Next]_vars /\ WF_vars(SysNext)
SpecFine == Init /\ [][Next]_vars /\ FairnessFine /\ \A c \in Ops : WF_vars(CmdExit(c))

(***************************************************************************)
(* Properties.                                                              *)
(***************************************************************************)
TypeOK ==
  /\ es \in {"up", "scan", "down", "off"}
  /\ \A c \in Ops :
       /\ jr[c].st \in Live \cup Term \cup {"none"}
       /\ p[c].proc \in {"none", "init", "ck", "rep", "spawning", "running", "polling"}
       /\ os[c].cmd \in {"none", "running", "exited"}
       /\ hrow[c] \in {"none", "open", "done"}

\* Each command starts at most once (node rules 1 to 4).
AtMostOnceExec == \A c \in Ops : os[c].execs <= 1

CmdGone(c) == os[c].cmd # "running" /\ ~os[c].bg

\* Once the hub has an op's result, nothing of the command is left running.
ResultPhysical == \A c \in Ops : hrow[c] = "done" => CmdGone(c)

Faults == cnt.exc + cnt.opc + cnt.node + cnt.stop

\* The result says what happened: `completed` only for a command that
\* exited on its own, unless the hub had canceled the op (the hub closes a
\* canceled row's result without showing it; see E1 in Executor.md),
\* `canceled` only if the hub canceled, `failed` only after a fault, and
\* never "no record" (the node loses no data here).
ResultTruthful ==
  \A c \in Ops :
    /\ hres[c] = "completed" => os[c].self \/ hcx[c]
    /\ hres[c] = "canceled" => hcx[c]
    /\ hres[c] = "failed" => Faults > 0
    /\ hres[c] # "lost"

\* The strict form of the first clause: `completed` only for a command that
\* exited on its own, canceled or not (E1).
CompletedMeansExited == \A c \in Ops : hres[c] = "completed" => os[c].self

\* Every op the hub started gets its result.
CallResult == \A c \in Ops : hrow[c] = "open" ~> hrow[c] = "done"

\* A cancel ends the op and its command, even one that would run forever.
CancelTakesEffect == \A c \in Ops : hcx[c] ~> (hrow[c] = "done" /\ CmdGone(c))

\* Every finished op's journal entry is eventually forgotten (node rule 6).
ResultsForgotten == \A c \in Ops : jr[c].st \in Term ~> jr[c].st = "none"

=============================================================================
