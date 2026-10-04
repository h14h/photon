------------------------------- MODULE Coordinator -------------------------------
(***************************************************************************)
(* One node session's coordinator (the session core, apps/node/lib/       *)
(* photon_node/harness/session.ex, run by the server in coordinator.ex)    *)
(* with its environment: the hub's input outbox and                        *)
(* websocket, the session log (Store), the LLM task, the shell operation   *)
(* processes (ops/shell.ex) and the OS commands they run, and faults:      *)
(* coordinator crashes (at any point inside a handler), abrupt node        *)
(* crashes, op process crashes, websocket drops, duplicate deliveries, and *)
(* a tool that disappears between coordinator incarnations. It models the *)
(* code after the verification fixes; Coordinator.md lists them.           *)
(*                                                                         *)
(* The coordinator is written as pure functions over a record S that       *)
(* accumulate an ordered list of side effects S.fx (log appends, LLM task  *)
(* spawn/kill, Ops.add, Ops.cancel). A handler step either applies all of  *)
(* its effects, or crashes after any prefix of them (Store.append fsyncs   *)
(* each record, so a crash leaves exactly a prefix of the handler's        *)
(* records in the log). The code has the same shape: Session functions    *)
(* take and return a %Session{} token that collects effects in order, and  *)
(* Coordinator runs them. Operators are named after the functions they     *)
(* model, in session.ex unless another file or module is named. See        *)
(* Coordinator.md for the mapping and results.                             *)
(*                                                                         *)
(* TLC note: operator arguments and LET definitions are evaluated lazily   *)
(* and are not cached when TLC evaluates invariants, ENABLED, or temporal  *)
(* formulas. Every operator that uses its state argument more than once    *)
(* therefore binds it first with Strict, or the chained state-passing      *)
(* below costs exponential time.                                           *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
  ExtInputs,      \* IDs of external inputs the hub may send (e.g. {1, 2})
  MaxCalls,       \* tool calls the model may make over the whole run
  MaxPerResp,     \* tool calls per model response
  MaxHB,          \* heartbeats that may fire
  MaxStops,       \* "stop" commands from the hub
  MaxCrash,       \* coordinator crashes (the supervisor restarts it)
  MaxNodeCrash,   \* abrupt node (BEAM) crashes
  MaxOpCrash,     \* operation process crashes
  MaxDisconnect,  \* websocket drops
  MaxDup,         \* duplicate deliveries of an input the hub already sent
  HBEnabled,      \* PHOTON_HEARTBEAT_MS > 0
  BgChildren,     \* commands may leave background children in their group
  ToolMayVanish   \* the tool may be unavailable to a later incarnation

VARIABLES
  log,        \* the session log (Store), as a sequence of records
  cs,         \* coordinator process: "down" | "crashed" | "init" | "up"
  S,          \* the coordinator's in-memory state (meaningful in init/up)
  inq,        \* mailbox: deliveries ({:deliver, ...} calls) from the Connection, in order
  opq,        \* mailbox: {:op_update, _} messages, per operation, in order
  tasks,      \* LLM tasks alive (turn IDs), including orphans
  nextTurn,   \* fresh turn IDs
  nextCall,   \* fresh call IDs (the model's tool-call budget)
  kind,       \* per call: "ok" (valid, one operation) or "err" (invalid)
  op,         \* per operation: its op process (ops/shell.ex)
  os,         \* per operation: the OS command, its group, its exit file
  hubSent,    \* external inputs the user has sent (the hub's outbox)
  connected,  \* websocket joined
  nodeUp,     \* BEAM running
  toolGone,   \* the tool no longer resolves for new incarnations
  cnt         \* fault and event budgets

vars == <<log, cs, S, inq, opq, tasks, nextTurn, nextCall, kind, op, os,
          hubSent, connected, nodeUp, toolGone, cnt>>

Calls == 1..MaxCalls                          \* operation ID = call ID
Term  == {"completed", "failed", "canceled"}   \* Operation.terminal_statuses/0
Live  == {"ready", "proc0", "proc1", "read"}   \* ready; awaiting/process
                                              \* without pgid; with pgid;
                                              \* awaiting/read
StopId(n) == 100 + n
HBId(n)   == 200 + n
Max(X) == CHOOSE x \in X : \A y \in X : x >= y
Min2(a, b) == IF a < b THEN a ELSE b

\* Evaluate x once and hand the value to F.
Strict(x, F(_)) == CHOOSE r \in {F(v) : v \in {x}} : TRUE

(***************************************************************************)
(* Log records (the Store moduledoc), reduced to the fields that matter. *)
(***************************************************************************)
R0 == [k |-> "none", id |-> 0, ik |-> "none", t |-> 0, cl |-> {}, c |-> 0,
       st |-> "none", sn |-> "none", s |-> "none"]
RecInput(i, ik)      == [R0 EXCEPT !.k = "input", !.id = i, !.ik = ik]
RecTurn(t)           == [R0 EXCEPT !.k = "turn", !.t = t]
RecResp(t, cl)       == [R0 EXCEPT !.k = "resp", !.t = t, !.cl = cl]
RecStatus(c, st, sn) == [R0 EXCEPT !.k = "status", !.c = c, !.st = st, !.sn = sn]
RecOp(c, sn)         == [R0 EXCEPT !.k = "op", !.c = c, !.sn = sn]
RecState(s)          == [R0 EXCEPT !.k = "state", !.s = s]

Fx(e, r, c, sn) == [e |-> e, r |-> r, c |-> c, sn |-> sn]

(***************************************************************************)
(* Coordinator state (the %Session{} struct; the server adds only the     *)
(* open log, the task, timer refs and monitors), plus ghosts:             *)
(*   ph/real  : the Context's tool results per call: "S" staged,          *)
(*              "C" committed (Context.add_tool_result/5, commit/1)      *)
(*   avail    : whether the tool resolves in this incarnation             *)
(*   dupReal  : a second real result was added for a call                 *)
(*   emptyTurn: a turn was applied with nothing pending                   *)
(*   idleMsg  : an :idle_stop message is waiting in the mailbox           *)
(*   deferred : external inputs held while a hard stop finishes            *)
(***************************************************************************)
Base(avail) ==
  [seen |-> {}, turn |-> 0, calls |-> {}, cst |-> [c \in Calls |-> "nil"],
   ops |-> [c \in Calls |-> "none"], available |-> 0, delivered |-> 0,
   turnInputs |-> 0, callModel |-> FALSE, llm |-> 0, grace |-> {},
   hb |-> "off", stop |-> "none", busy |-> FALSE,
   ph |-> [c \in Calls |-> {}], real |-> [c \in Calls |-> {}],
   dupReal |-> FALSE, emptyTurn |-> FALSE, avail |-> avail, nt |-> 0,
   sched |-> {}, fx |-> <<>>, idleMsg |-> FALSE, deferred |-> <<>>]

DownS == Base(TRUE)

Pending(St0) == Strict(St0, LAMBDA St : St.available - St.delivered)   \* pending/1
NonTerm(St0) == Strict(St0, LAMBDA St : {c \in Calls : St.ops[c] \in Live})  \* non_terminal_ops/1
IdleS(St0) ==                                                          \* idle?/1
  Strict(St0, LAMBDA St : St.llm = 0 /\ St.available = St.delivered
                          /\ St.calls = {} /\ \A c \in Calls : St.ops[c] \notin Live)

CommitCtx(set) == IF "S" \in set THEN (set \ {"S"}) \cup {"C"} ELSE set

\* finish_call/3 (and leave_grace/2)
Finish(St0, c) == Strict(St0, LAMBDA St :
  [St EXCEPT !.ph[c] = @ \ {"S"}, !.real[c] = @ \cup {"S"},
             !.dupReal = @ \/ (St.real[c] # {}), !.calls = @ \ {c},
             !.grace = @ \ {c}, !.available = @ + 1])

\* add_tool_result/2. A call whose tool no longer resolves (~avail) is
\* still finished once its operation is terminal, with a generic result.
AddToolResult(St0, c) == Strict(St0, LAMBDA St :
  IF St.cst[c] = "err" THEN Finish(St, c)          \* error-only
  ELSE IF St.ops[c] = "none" THEN St               \* snapshot not known yet
  ELSE IF St.ops[c] \in Term THEN Finish(St, c)
  ELSE [St EXCEPT !.ph[c] = @ \cup {"S"}])         \* placeholder

\* apply_item/2: live right after each persist (record/3), and on start
\* for each record in the log (replay/2)
ApplyItem(St0, r) == Strict(St0, LAMBDA St :
  CASE r.k = "input" ->                                         \* apply_input/2
         IF r.ik \in {"ext", "hb"} THEN [St EXCEPT !.available = @ + 1]
         ELSE IF r.ik = "hard" /\ St.stop = "none" THEN [St EXCEPT !.stop = "hard"]
         ELSE St
    [] r.k = "turn" ->
         [St EXCEPT !.turn = r.t, !.turnInputs = St.available,
                    !.emptyTurn = @ \/ (St.available = St.delivered),
                    !.ph = [c \in Calls |-> CommitCtx(St.ph[c])],
                    !.real = [c \in Calls |-> CommitCtx(St.real[c])]]
    [] r.k = "resp" ->                                          \* add_message/4
         Strict(IF St.turn # 0 /\ r.t = St.turn
                THEN [St EXCEPT !.delivered = St.turnInputs] ELSE St,
                LAMBDA S1 :
                  [S1 EXCEPT !.calls = @ \cup r.cl,
                             !.cst = [c \in Calls |-> IF c \in r.cl THEN "nil" ELSE S1.cst[c]]])
    [] r.k = "status" ->                                        \* apply_status/3
         Strict(IF r.sn # "none" THEN [St EXCEPT !.ops[r.c] = r.sn] ELSE St,
                LAMBDA S1 :
                  IF r.c \in S1.calls
                  THEN AddToolResult([S1 EXCEPT !.cst[r.c] = r.st], r.c)
                  ELSE S1)
    [] r.k = "op" -> [St EXCEPT !.ops[r.c] = r.sn]              \* overlay/2
    [] r.k = "state" ->                                         \* apply_run_state/2
         IF r.s = "stopped"
         THEN [St EXCEPT !.busy = FALSE, !.delivered = St.available, !.stop = "none"]
         ELSE IF r.s = "idle"
         THEN [St EXCEPT !.busy = FALSE, !.stop = "none"]
         ELSE [St EXCEPT !.busy = TRUE]
    [] OTHER -> St)

RECURSIVE ReplayFrom(_, _, _)
ReplayFrom(St0, L, i) == Strict(St0, LAMBDA St :
  IF i > Len(L) THEN St ELSE ReplayFrom(ApplyItem(St, L[i]), L, i + 1))

\* Coordinator.init/1 and replay/2: replay the log, seed the inbox with
\* logged input IDs
Replay(L, avail) ==
  [ReplayFrom(Base(avail), L, 1) EXCEPT
     !.seen = {L[i].id : i \in {j \in 1..Len(L) : L[j].k = "input"}}]

\* record/3's {:persist, kind, data} effect; Coordinator runs it as
\* Store.append/3 and Connection.event/3.
Persist(St, r) == [St EXCEPT !.fx = Append(@, Fx("log", r, 0, "none"))]
PersistApply(St, r) == ApplyItem(Persist(St, r), r)

ClearGrace(St) == [St EXCEPT !.grace = {}]                                \* clear_grace/1
AcceptStop(St0) == Strict(St0, LAMBDA St :                              \* accept_stop/1
  IF St.stop = "none" THEN [St EXCEPT !.stop = "hard"] ELSE St)

\* handle_input/3 (Inbox.accept dedupes on seen IDs). New external input
\* that arrives while a hard stop is finishing is held (deferred) until
\* "stopped" is written.
HandleInput(St0, m) == Strict(St0, LAMBDA St :
  IF m.id \in St.seen THEN St
  ELSE IF m.ik = "ext" /\ St.stop # "none" THEN [St EXCEPT !.deferred = Append(@, m)]
  ELSE Strict(PersistApply([St EXCEPT !.seen = @ \cup {m.id}], RecInput(m.id, m.ik)),
              LAMBDA S1 :
                CASE m.ik = "hard" -> ClearGrace(AcceptStop(S1))
                  [] m.ik = "ext"  -> [S1 EXCEPT !.grace = {}, !.callModel = TRUE]
                  [] OTHER         -> ClearGrace(S1)))

\* handle_op_update/3 (op_update/3). "ck0" is the shell's call (Coordinator.checkpoint/2)
\* asking to have its "process" checkpoint persisted before it starts the
\* command: answered ok once persisted, cancel during a hard stop, ignored
\* for an operation that is unknown or finished.
Ack(St, c, a) == [St EXCEPT !.fx = Append(@, Fx("ack", R0, c, a))]
HandleOpUpdate(St0, c, sn) == Strict(St0, LAMBDA St :
  IF sn = "ck0" THEN
    IF St.ops[c] \notin Live THEN Ack(St, c, "ignored")
    ELSE IF St.stop # "none" THEN Ack(St, c, "cancel")
    ELSE Ack([Persist(St, RecOp(c, "proc0")) EXCEPT !.ops[c] = "proc0"], c, "ok")
  ELSE IF St.ops[c] \in Live THEN [Persist(St, RecOp(c, sn)) EXCEPT !.ops[c] = sn] ELSE St)

RECURSIVE DrainIn(_, _, _)
DrainIn(St0, Q, i) == Strict(St0, LAMBDA St :
  IF i > Len(Q) THEN St ELSE DrainIn(HandleInput(St, Q[i]), Q, i + 1))
RECURSIVE DrainOp(_, _, _, _)
DrainOp(St0, c, Q, i) == Strict(St0, LAMBDA St :
  IF i > Len(Q) THEN St ELSE DrainOp(HandleOpUpdate(St, c, Q[i]), c, Q, i + 1))
RECURSIVE DrainOps(_, _, _)
DrainOps(St0, Qs, c) == Strict(St0, LAMBDA St :
  IF c > MaxCalls THEN St ELSE DrainOps(DrainOp(St, c, Qs[c], 1), Qs, c + 1))

\* reconcile/1 (in call order)
RECURSIVE ReconcileFrom(_, _)
ReconcileFrom(St0, c) == Strict(St0, LAMBDA St :
  IF c > MaxCalls THEN St
  ELSE ReconcileFrom(IF c \in St.calls /\ St.cst[c] = "ok" /\ St.ops[c] \in Term
                     THEN PersistApply(St, RecStatus(c, "ok", St.ops[c]))
                     ELSE St, c + 1))
Reconcile(St) == ReconcileFrom(St, 1)

\* Coordinator's slurp/1: queued inputs, then op updates, each handed to the
\* core and its effects run, then reconcile/1
Slurp(St, Q, Qs) == Reconcile(DrainOps(DrainIn(St, Q, 1), Qs, 1))

\* schedule_tool_calls/1. K: the call's validity.
RECURSIVE SchedFrom(_, _, _)
SchedFrom(St0, K, c) == Strict(St0, LAMBDA St :
  IF c > MaxCalls THEN St
  ELSE SchedFrom(
         IF c \in St.calls /\ St.cst[c] = "nil"
         THEN LET st == IF K[c] = "ok" /\ St.avail THEN "ok" ELSE "err"
                  sn == IF st = "ok" THEN "ready" ELSE "none"
              IN [PersistApply(St, RecStatus(c, st, sn)) EXCEPT !.sched = @ \cup {c}]
         ELSE St, K, c + 1))
Schedule(St, K) == SchedFrom([St EXCEPT !.sched = {}], K, 1)

\* dispatch/2: {:dispatch, op} effects, run as Ops.add/2 (which never fails
\* for logged op types; if it did, dispatch_failed/3 would fail the op)
RECURSIVE DispFrom(_, _, _)
DispFrom(St0, D, c) == Strict(St0, LAMBDA St :
  IF c > MaxCalls THEN St
  ELSE DispFrom(IF c \in D /\ St.ops[c] \in Live
                THEN [St EXCEPT !.fx = Append(@, Fx("add", R0, c, St.ops[c]))]
                ELSE St, D, c + 1))
Dispatch(St, D) == DispFrom(St, D, 1)

RECURSIVE CancelFrom(_, _, _)
CancelFrom(St0, D, c) == Strict(St0, LAMBDA St :
  IF c > MaxCalls THEN St
  ELSE CancelFrom(IF c \in D THEN [St EXCEPT !.fx = Append(@, Fx("cancel", R0, c, "none"))]
                  ELSE St, D, c + 1))

\* cancel_llm/1: a :cancel_request effect
CancelLLM(St0) == Strict(St0, LAMBDA St :
  IF St.llm = 0 THEN St
  ELSE [St EXCEPT !.llm = 0, !.fx = Append(@, Fx("kill", R0, St.llm, "none"))])

\* request_model_response/1: a {:request, ...} effect after the turn's
\* persist; Coordinator starts the task (ModelRequest.start/3)
RequestTurn(St0) == Strict(CancelLLM(St0), LAMBDA S1 :
  Strict(PersistApply(S1, RecTurn(S1.nt)), LAMBDA S2 :
    [S2 EXCEPT !.llm = S1.nt, !.callModel = FALSE, !.nt = S1.nt + 1,
               !.fx = Append(@, Fx("spawn", R0, S1.nt, "none"))]))

\* handle_stop/1 (request_stop/1, finish_stop/1)
HandleStop(St0) == Strict(St0, LAMBDA St :
  Strict(IF St.stop = "requested" THEN St
         ELSE Strict(CancelLLM(St), LAMBDA S0 :
                [CancelFrom(S0, NonTerm(S0), 1) EXCEPT !.stop = "requested",
                                                       !.callModel = FALSE]),
         LAMBDA S1 :
           IF NonTerm(S1) = {}
           THEN [Persist(S1, RecState("stopped")) EXCEPT !.stop = "none",
                    !.delivered = S1.available, !.busy = FALSE, !.callModel = FALSE]
           ELSE S1))

\* arm_heartbeat/1
ArmHB(St0) == Strict(St0, LAMBDA St :
  [St EXCEPT !.hb = IF HBEnabled /\ St.llm = 0 /\ St.stop = "none"
                       /\ St.available = St.delivered /\ St.calls # {}
                    THEN "armed" ELSE "off"])

\* record_run_state/1
RecordRun(St0) == Strict(St0, LAMBDA St :
  LET b == ~IdleS(St) IN
  IF b = St.busy THEN St
  ELSE IF b THEN [Persist(St, RecState("running")) EXCEPT !.busy = TRUE]
  ELSE [Persist(St, RecState("idle")) EXCEPT !.busy = FALSE])

MaybeTurn(St0) == Strict(St0, LAMBDA St :
  IF St.callModel \/ (St.available > St.delivered /\ St.llm = 0 /\ St.grace = {})
  THEN ClearGrace(RequestTurn(St))
  ELSE St)

\* resume_deferred/1: once "stopped" is written, held inputs are handled.
ResumeDeferred(St0) == Strict(St0, LAMBDA St :
  DrainIn([St EXCEPT !.deferred = <<>>], St.deferred, 1))

\* decide/1 (next_step/1; arm_idle_stop: see IdleFire)
Decide(St0) == Strict(St0, LAMBDA St :
  RecordRun(ArmHB(
    IF St.stop # "none"
    THEN Strict(HandleStop(St), LAMBDA S1 :
           IF S1.stop = "none" THEN MaybeTurn(ResumeDeferred(S1)) ELSE S1)
    ELSE MaybeTurn(St))))

(***************************************************************************)
(* Handlers. Each returns the new state with its effects in .fx.          *)
(***************************************************************************)
\* Coordinator.handle_continue(:start): resume/1, then decide/1
HContinue(St, K) ==
  Strict(Schedule(St, K), LAMBDA S1 :
    Strict(Reconcile(S1), LAMBDA S2 :
      Strict(Dispatch(S2, NonTerm(S2)), LAMBDA S3 :
        Decide(IF (\E c \in S1.sched : S1.cst[c] = "err") \/ S3.available > S3.delivered
               THEN [S3 EXCEPT !.callModel = TRUE] ELSE S3))))

\* Coordinator.handle_call({:deliver, ...}): deliver/4, slurp, decide/1
HInput(St, m, Q, Qs) == Decide(Slurp(HandleInput(St, m), Q, Qs))

\* Coordinator.handle_info({:op_update, _}): op_update/3, slurp, decide/1
HOp(St, c, sn, Q, Qs) == Decide(Slurp(HandleOpUpdate(St, c, sn), Q, Qs))

\* Coordinator.handle_info({ref, result}) / {:DOWN, ...}: model_response/2
\* (process_model_response/3), slurp, decide/1.
\* The task has finished (its reply is in hand), so it leaves `tasks`.
HLLM(St0, cl, K, Q, Qs) == Strict(St0, LAMBDA St :
  Strict(Schedule(PersistApply(CancelLLM(St), RecResp(St.llm, cl)), K), LAMBDA S2 :
    Strict(Dispatch(S2, {c \in S2.sched : S2.cst[c] = "ok"}), LAMBDA S3 :
      Decide(Slurp(
        IF \E c \in S2.sched : S2.cst[c] = "err" THEN [S3 EXCEPT !.callModel = TRUE]
        ELSE IF S2.sched # {} THEN [S3 EXCEPT !.grace = S2.sched]   \* arm_grace/2
        ELSE S3, Q, Qs)))))

\* Coordinator.handle_info({:grace, ref}): grace_expired/1, decide/1
HGrace(St) == Decide([St EXCEPT !.grace = {}])

\* Coordinator.handle_info({:heartbeat, ref}): heartbeat_fired/1
\* (post_heartbeat/1), decide/1
HHeartbeat(St, n) == Decide(HandleInput([St EXCEPT !.hb = "off"], [ik |-> "hb", id |-> HBId(n)]))

(***************************************************************************)
(* Environment.                                                            *)
(***************************************************************************)
NoOp == [proc |-> "none", init |-> "none", snap |-> "none",
         cancel |-> FALSE, canceled |-> FALSE, resend |-> FALSE]
NewOp(sn) == [proc |-> "init", init |-> sn, snap |-> sn,
              cancel |-> FALSE, canceled |-> FALSE, resend |-> FALSE]
\* pidf: the wrapper's pid file exists (written as the command starts).
NoOS == [cmd |-> "none", bg |-> FALSE, exit |-> FALSE, execs |-> 0, pidf |-> FALSE]
EmptyQs == [c \in Calls |-> <<>>]
CoordLive == cs \in {"init", "up"}

\* Applying a handler's effects to the world.
Eff(E0, f) == Strict(E0, LAMBDA E :
  CASE f.e = "log"    -> [E EXCEPT !.log = Append(@, f.r)]
    [] f.e = "spawn"  -> [E EXCEPT !.tasks = @ \cup {f.c}]
    [] f.e = "kill"   -> [E EXCEPT !.tasks = @ \ {f.c}]
    [] f.e = "add"    ->                                          \* Ops.add/2
         IF E.op[f.c].proc # "none" THEN [E EXCEPT !.op[f.c].resend = TRUE]
         ELSE [E EXCEPT !.op[f.c] = NewOp(f.sn)]
    [] f.e = "ack"    ->                     \* the reply to Coordinator.checkpoint/2
         IF E.op[f.c].proc # "await" THEN E
         ELSE IF f.sn = "ok" THEN [E EXCEPT !.op[f.c].proc = "go"]
         ELSE IF f.sn = "cancel" THEN [E EXCEPT !.op[f.c].proc = "cancelling"]
         ELSE [E EXCEPT !.op[f.c] = NoOp]
    [] OTHER          ->                                          \* cancel: Ops.cancel/1
         IF E.op[f.c].proc # "none" THEN [E EXCEPT !.op[f.c].cancel = TRUE] ELSE E)
RECURSIVE Fold(_, _, _)
Fold(E0, fx, i) == Strict(E0, LAMBDA E :
  IF i > Len(fx) THEN E ELSE Fold(Eff(E, fx[i]), fx, i + 1))
World == [log |-> log, tasks |-> tasks, op |-> op]

LastState(L) ==
  LET idx == {i \in 1..Len(L) : L[i].k = "state"}
  IN IF idx = {} THEN "none" ELSE L[Max(idx)].s

\* Coordinator.init/1: a new incarnation replays the log (replay/2).
StartS == [Replay(log, ~toolGone) EXCEPT !.nt = nextTurn]

\* A handler that runs to completion.
Commit(R0x, Q2, Qs2, K2, nc2, cnt2) ==
  \E R \in {R0x} :
    \E E \in {Fold(World, R.fx, 1)} :
      /\ log' = E.log /\ tasks' = E.tasks /\ op' = E.op
      /\ S' = [R EXCEPT !.fx = <<>>, !.sched = {}]
      /\ cs' = "up" /\ inq' = Q2 /\ opq' = Qs2
      /\ kind' = K2 /\ nextCall' = nc2 /\ nextTurn' = R.nt /\ cnt' = cnt2
      /\ UNCHANGED <<os, hubSent, connected, nodeUp, toolGone>>

\* Deliveries whose call is still waiting (Harness.deliver/3 for external
\* inputs, Harness.stop/1 for hard stops): retried with the next
\* incarnation when this one dies.
IsDelivery(m) == m.ik \in {"ext", "hard"}
Retried == SelectSeq(S.deferred \o inq, IsDelivery)

\* A handler that crashes after k of its effects. The model request task is
\* linked, so it dies with the coordinator. A shell waiting in
\* Coordinator.checkpoint/2 gets an exit and stops without starting its
\* command. Pending deliveries are retried (Retried).
CrashIn(R0x, K2, nc2, cnt2) ==
  /\ cnt.crash < MaxCrash
  /\ \E R \in {R0x} :
       /\ \E k \in 0..Len(R.fx) :
            \E E \in {Fold(World, SubSeq(R.fx, 1, k), 1)} :
              /\ log' = E.log
              /\ op' = [c \in Calls |-> IF E.op[c].proc = "await" THEN NoOp ELSE E.op[c]]
              /\ tasks' = {}
       /\ nextTurn' = R.nt
  /\ cs' = "crashed" /\ S' = DownS /\ inq' = Retried /\ opq' = EmptyQs
  /\ kind' = K2 /\ nextCall' = nc2
  /\ cnt' = [cnt2 EXCEPT !.crash = @ + 1]
  /\ UNCHANGED <<os, hubSent, connected, nodeUp, toolGone>>

\* The node dies after k of the handler's effects: every BEAM process
\* (coordinator, LLM tasks, op processes) is gone; OS commands survive.
NodeCrashIn(R0x, K2, nc2, cnt2) ==
  /\ cnt.node < MaxNodeCrash
  /\ \E R \in {R0x} :
       /\ \E k \in 0..Len(R.fx) : log' = Fold(World, SubSeq(R.fx, 1, k), 1).log
       /\ nextTurn' = R.nt
  /\ tasks' = {} /\ op' = [c \in Calls |-> NoOp]
  /\ cs' = "down" /\ S' = DownS /\ inq' = <<>> /\ opq' = EmptyQs
  /\ nodeUp' = FALSE /\ connected' = FALSE
  /\ kind' = K2 /\ nextCall' = nc2
  /\ cnt' = [cnt2 EXCEPT !.node = @ + 1]
  /\ UNCHANGED <<os, hubSent, toolGone>>

Exec(mode, R, Q2, Qs2, K2, nc2, cnt2) ==
  CASE mode = "ok"    -> Commit(R, Q2, Qs2, K2, nc2, cnt2)
    [] mode = "crash" -> CrashIn(R, K2, nc2, cnt2)
    [] OTHER          -> NodeCrashIn(R, K2, nc2, cnt2)

Modes == {"ok", "crash", "node"}

(***************************************************************************)
(* Coordinator steps.                                                      *)
(***************************************************************************)
ContinueStep(mode) ==
  /\ cs = "init"
  /\ Exec(mode, HContinue(S, kind), inq, opq, kind, nextCall, cnt)

InputStep(mode) ==
  /\ cs = "up" /\ inq # <<>> /\ ~S.idleMsg
  /\ Exec(mode, HInput(S, Head(inq), Tail(inq), opq), <<>>, EmptyQs, kind, nextCall, cnt)

OpStep(mode, c) ==
  /\ cs = "up" /\ opq[c] # <<>> /\ ~S.idleMsg
  /\ Exec(mode, HOp(S, c, Head(opq[c]), inq, [opq EXCEPT ![c] = Tail(@)]),
          <<>>, EmptyQs, kind, nextCall, cnt)

\* The model's answer: n new tool calls, each valid ("ok") or not ("err").
\* Kinds are generated in sorted order (ok before err) to save states; a
\* failed response (no message) behaves like a text answer here.
Responses ==
  UNION {{ks \in [1..n -> {"ok", "err"}] :
            \A j \in 1..n : \A j2 \in 1..n : j < j2 => (ks[j] = "ok" \/ ks[j2] = "err")}
         : n \in 0..Min2(MaxPerResp, MaxCalls - nextCall + 1)}

LLMStep(mode) ==
  /\ cs = "up" /\ S.llm # 0 /\ ~S.idleMsg
  /\ \E ks \in Responses :
       LET n  == Len(ks)
           cl == {nextCall + j - 1 : j \in 1..n}
           K2 == [c \in Calls |-> IF c \in cl THEN ks[c - nextCall + 1] ELSE kind[c]]
       IN Exec(mode, HLLM(S, cl, K2, inq, opq), <<>>, EmptyQs, K2, nextCall + n, cnt)

GraceStep(mode) ==
  /\ cs = "up" /\ S.grace # {} /\ ~S.idleMsg
  /\ Exec(mode, HGrace(S), inq, opq, kind, nextCall, cnt)

HBStep(mode) ==
  /\ cs = "up" /\ S.hb = "armed" /\ cnt.hb < MaxHB /\ ~S.idleMsg
  /\ Exec(mode, HHeartbeat(S, cnt.hb), inq, opq, kind, nextCall,
          [cnt EXCEPT !.hb = @ + 1])

\* arm_idle_stop/1 arms a 10-minute timer whenever the
\* coordinator is idle. Time is abstract here, so the timer may fire at
\* any point while the coordinator is idle and no input is queued (an
\* input queued earlier would be handled first). Once fired, :idle_stop
\* is ahead of any input that arrives later.
IdleFire ==
  /\ cs = "up" /\ IdleS(S) /\ inq = <<>> /\ ~S.idleMsg
  /\ S' = [S EXCEPT !.idleMsg = TRUE]
  /\ UNCHANGED <<log, cs, inq, opq, tasks, nextTurn, nextCall, kind, op, os,
                 hubSent, connected, nodeUp, toolGone, cnt>>

\* Coordinator.handle_info(:idle_stop): checks idle?/1 only; the process exits
\* (restart: :transient, reason :normal, so the supervisor does not restart
\* it). Deliveries and stops behind it in the mailbox get an exit and are
\* retried with a new coordinator (Harness.deliver/3, Harness.stop/1).
IdleStop ==
  /\ cs = "up" /\ S.idleMsg
  /\ IF IdleS(S)
     THEN IF Retried = <<>>
          THEN /\ cs' = "down" /\ S' = DownS /\ inq' = <<>> /\ opq' = EmptyQs
          ELSE /\ cs' = "init" /\ S' = StartS /\ inq' = Retried /\ opq' = EmptyQs
     ELSE /\ S' = [S EXCEPT !.idleMsg = FALSE] /\ UNCHANGED <<cs, inq, opq>>
  /\ UNCHANGED <<log, tasks, nextTurn, nextCall, kind, op, os, hubSent,
                 connected, nodeUp, toolGone, cnt>>

\* The session supervisor restarts a crashed coordinator; retried
\* deliveries (inq) reach the new incarnation.
SupervisorRestart ==
  /\ cs = "crashed"
  /\ cs' = "init" /\ S' = StartS /\ opq' = EmptyQs
  /\ UNCHANGED <<log, inq, tasks, nextTurn, nextCall, kind, op, os, hubSent,
                 connected, nodeUp, toolGone, cnt>>

\* Harness.deliver/3: ensure_started, then a call answered once the input
\* is persisted. (Deliveries are serial per connection; several queued
\* here stand for those waiting their turn.)
DeliverSeq(ms) ==
  IF CoordLive
  THEN /\ inq' = inq \o ms /\ UNCHANGED <<cs, S, opq>>
  ELSE /\ cs' = "init" /\ S' = StartS /\ inq' = inq \o ms /\ opq' = EmptyQs

ExtMsg(i) == [ik |-> "ext", id |-> i]

\* NodeSessions.send_input/3: store in the outbox, push if connected.
HubSend(i) ==
  /\ i \notin hubSent
  /\ hubSent' = hubSent \cup {i}
  /\ IF connected THEN DeliverSeq(<<ExtMsg(i)>>) ELSE UNCHANGED <<cs, S, inq, opq>>
  /\ UNCHANGED <<log, tasks, nextTurn, nextCall, kind, op, os, connected, nodeUp, toolGone, cnt>>

\* A repeated push of an input (resend, duplicated command).
HubDup(i) ==
  /\ cnt.dup < MaxDup /\ connected /\ i \in hubSent
  /\ DeliverSeq(<<ExtMsg(i)>>)
  /\ cnt' = [cnt EXCEPT !.dup = @ + 1]
  /\ UNCHANGED <<log, tasks, nextTurn, nextCall, kind, op, os, hubSent, connected, nodeUp, toolGone>>

\* An external input logged after the last model response or "stopped".
LastIdxK(L, P(_)) == LET I == {i \in 1..Len(L) : P(L[i])} IN IF I = {} THEN 0 ELSE Max(I)
IsExtRec(r) == r.k = "input" /\ r.ik = "ext"
IsRespOrStopped(r) == r.k = "resp" \/ (r.k = "state" /\ r.s = "stopped")
UndeliveredExt(L) == LastIdxK(L, IsExtRec) > LastIdxK(L, IsRespOrStopped)

\* Harness.working?/1: the last state record is "running", or there is
\* external input the session never started on.
WorkingLog(L) == LastState(L) = "running" \/ UndeliveredExt(L)

\* NodeSessions.stop -> Harness.stop/1: the hard stop goes through the
\* same delivery call as an input, to the running coordinator, or to one
\* started for a session whose log says it is working; otherwise there is
\* nothing to stop. A coordinator that dies first hands it to the next one
\* (Retried).
HubStop ==
  /\ cnt.stops < MaxStops /\ connected
  /\ cnt' = [cnt EXCEPT !.stops = @ + 1]
  /\ IF CoordLive \/ WorkingLog(log)
     THEN DeliverSeq(<<[ik |-> "hard", id |-> StopId(cnt.stops)]>>)
     ELSE UNCHANGED <<cs, S, inq, opq>>
  /\ UNCHANGED <<log, tasks, nextTurn, nextCall, kind, op, os,
                 hubSent, connected, nodeUp, toolGone>>

Disconnect ==
  /\ cnt.disc < MaxDisconnect /\ connected
  /\ connected' = FALSE /\ cnt' = [cnt EXCEPT !.disc = @ + 1]
  /\ UNCHANGED <<log, cs, S, inq, opq, tasks, nextTurn, nextCall, kind, op, os,
                 hubSent, nodeUp, toolGone>>

\* Inputs the hub still holds as "queued": not yet in the session log.
Logged(i) == \E j \in 1..Len(log) : log[j].k = "input" /\ log[j].id = i
Queued == {i \in hubSent : ~Logged(i)}
RECURSIVE SetToSeq(_)
SetToSeq(X) == IF X = {} THEN <<>>
               ELSE LET m == CHOOSE x \in X : \A y \in X : x <= y
                    IN <<m>> \o SetToSeq(X \ {m})

\* Rejoin: NodeChannel :joined -> NodeSessions.resend_queued/1.
Reconnect ==
  /\ nodeUp /\ ~connected
  /\ connected' = TRUE
  /\ IF Queued = {} THEN UNCHANGED <<cs, S, inq, opq>>
     ELSE DeliverSeq([j \in 1..Cardinality(Queued) |-> ExtMsg(SetToSeq(Queued)[j])])
  /\ UNCHANGED <<log, tasks, nextTurn, nextCall, kind, op, os, hubSent, nodeUp, toolGone, cnt>>

\* An abrupt node crash while no handler is running.
NodeCrash ==
  /\ cnt.node < MaxNodeCrash /\ nodeUp /\ cs # "init"
  /\ tasks' = {} /\ op' = [c \in Calls |-> NoOp]
  /\ cs' = "down" /\ S' = DownS /\ inq' = <<>> /\ opq' = EmptyQs
  /\ nodeUp' = FALSE /\ connected' = FALSE
  /\ cnt' = [cnt EXCEPT !.node = @ + 1]
  /\ UNCHANGED <<log, nextTurn, nextCall, kind, os, hubSent, toolGone>>

\* Boot: Harness.resume_all/0 restarts a session that was working
\* (working?/1): its last state record is "running", or it has external
\* input it never started on.
NodeBoot ==
  /\ ~nodeUp
  /\ nodeUp' = TRUE
  /\ IF WorkingLog(log)
     THEN cs' = "init" /\ S' = StartS
     ELSE UNCHANGED <<cs, S>>
  /\ UNCHANGED <<log, inq, opq, tasks, nextTurn, nextCall, kind, op, os,
                 hubSent, connected, toolGone, cnt>>

\* Skills removed (or the tool disallowed) while no coordinator runs.
ToolVanish ==
  /\ ToolMayVanish /\ ~toolGone /\ ~CoordLive
  /\ toolGone' = TRUE
  /\ UNCHANGED <<log, cs, S, inq, opq, tasks, nextTurn, nextCall, kind, op, os,
                 hubSent, connected, nodeUp, cnt>>

\* An LLM task the coordinator no longer tracks runs to completion; its
\* reply goes to a dead pid or hits Coordinator's catch-all handle_info clause.
OrphanEnd(t) ==
  /\ t \in tasks /\ ~(CoordLive /\ t = S.llm)
  /\ tasks' = tasks \ {t}
  /\ UNCHANGED <<log, cs, S, inq, opq, nextTurn, nextCall, kind, op, os,
                 hubSent, connected, nodeUp, toolGone, cnt>>

(***************************************************************************)
(* Operation processes (ops/shell.ex) and OS commands.                    *)
(* Coordinator.report_op/2: dropped if no coordinator is running.          *)
(***************************************************************************)
Send(c, ms) == opq' = IF CoordLive THEN [opq EXCEPT ![c] = @ \o ms] ELSE opq

OpUnch == UNCHANGED <<log, cs, S, inq, tasks, nextTurn, nextCall, kind,
                      hubSent, connected, nodeUp, toolGone, cnt>>

KillOS(o) == [cmd |-> IF o.cmd = "running" THEN "exited" ELSE o.cmd, bg |-> FALSE,
              exit |-> o.exit \/ o.cmd = "running", execs |-> o.execs, pidf |-> o.pidf]

\* Recovery of a command started under pgid (snapshot proc1, or proc0 with
\* the wrapper's pid file): finish if it exited (killing what's left in its
\* group), wait if it still runs, else fail.
Recover(c) ==
  IF os[c].exit
  THEN /\ op' = [op EXCEPT ![c] = NoOp] /\ os' = [os EXCEPT ![c] = KillOS(@)]
       /\ Send(c, <<"read", "completed">>)
  ELSE IF os[c].cmd = "running" \/ os[c].bg
  THEN /\ op' = [op EXCEPT ![c].proc = "polling", ![c].snap = "proc1"]
       /\ Send(c, IF op[c].init = "proc0" THEN <<"proc1">> ELSE <<>>)
       /\ UNCHANGED os
  ELSE /\ op' = [op EXCEPT ![c] = NoOp] /\ Send(c, <<"failed">>) /\ UNCHANGED os

\* handle_continue(:start): prepare (a "ready" op asks the coordinator to
\* persist its "process" checkpoint and waits, "await"), or recover.
OpInit(c) ==
  /\ op[c].proc = "init"
  /\ LET sn == op[c].init IN
     CASE sn = "ready" ->
            IF CoordLive
            THEN /\ op' = [op EXCEPT ![c].proc = "await"]
                 /\ Send(c, <<"ck0">>) /\ UNCHANGED os
            ELSE \* no coordinator answers: stop without starting anything
                 /\ op' = [op EXCEPT ![c] = NoOp] /\ UNCHANGED <<os, opq>>
       [] sn = "proc0" ->
            IF os[c].pidf THEN Recover(c)
            ELSE /\ op' = [op EXCEPT ![c] = NoOp] /\ Send(c, <<"failed">>) /\ UNCHANGED os
       [] sn = "proc1" -> Recover(c)
       [] OTHER ->  \* "read": Shell finish/2
            /\ op' = [op EXCEPT ![c] = NoOp] /\ Send(c, <<"completed">>) /\ UNCHANGED os
  /\ OpUnch

\* The checkpoint was confirmed: start the command (the wrapper writes its
\* pid file as it starts it).
OpSpawn(c) ==
  /\ op[c].proc = "go"
  /\ op' = [op EXCEPT ![c].proc = "spawning", ![c].snap = "proc0"]
  /\ os' = [os EXCEPT ![c] = [cmd |-> "running", bg |-> os[c].bg, exit |-> FALSE,
                              execs |-> os[c].execs + 1, pidf |-> TRUE]]
  /\ UNCHANGED opq /\ OpUnch

\* The coordinator answered cancel (a hard stop is under way): the
\* operation is canceled without starting the command.
OpCancelAck(c) ==
  /\ op[c].proc = "cancelling"
  /\ op' = [op EXCEPT ![c] = NoOp]
  /\ Send(c, <<"canceled">>)
  /\ UNCHANGED os /\ OpUnch

\* The wrapper prints "pid N". A cancel that came before it kills the
\* group now.
PidLine(c) ==
  /\ op[c].proc = "spawning"
  /\ op' = [op EXCEPT ![c].proc = "running", ![c].snap = "proc1"]
  /\ Send(c, <<"proc1">>)
  /\ os' = IF op[c].canceled THEN [os EXCEPT ![c] = KillOS(@)] ELSE os
  /\ OpUnch

\* The command exits on its own; the wrapper writes the exit file.
CmdExit(c) ==
  /\ os[c].cmd = "running"
  /\ \E b \in (IF BgChildren THEN BOOLEAN ELSE {FALSE}) :
       os' = [os EXCEPT ![c] = [cmd |-> "exited", bg |-> os[c].bg \/ b,
                                exit |-> TRUE, execs |-> os[c].execs, pidf |-> os[c].pidf]]
  /\ UNCHANGED <<op, opq>> /\ OpUnch

\* A background child left in the group exits (daemons may never).
BgExit(c) ==
  /\ os[c].bg
  /\ os' = [os EXCEPT ![c].bg = FALSE]
  /\ UNCHANGED <<op, opq>> /\ OpUnch

\* {:exit_status, _} from the wrapper port: Shell exited/2, after the group
\* is killed (kill_group/3 waits without blocking the process; messages
\* that arrive meanwhile are postponed, so the step stays atomic)
PortExit(c) ==
  /\ op[c].proc = "running" /\ os[c].cmd = "exited"
  /\ os' = [os EXCEPT ![c].bg = FALSE]
  /\ op' = [op EXCEPT ![c] = NoOp]
  /\ Send(c, IF op[c].canceled THEN <<"canceled">> ELSE <<"read", "completed">>)
  /\ OpUnch

\* :cancel, Shell handle_info(:cancel, _)
OpCancel(c) ==
  /\ op[c].cancel /\ op[c].proc \in {"spawning", "running", "polling"}
  /\ CASE op[c].proc = "spawning" ->      \* kill_group(nil) is a no-op
            /\ op' = [op EXCEPT ![c].cancel = FALSE, ![c].canceled = TRUE]
            /\ UNCHANGED <<os, opq>>
       [] op[c].proc = "running" ->
            /\ op' = [op EXCEPT ![c].cancel = FALSE, ![c].canceled = TRUE]
            /\ os' = [os EXCEPT ![c] = KillOS(@)]
            /\ UNCHANGED opq
       [] OTHER ->                        \* polling: port nil -> cancel/1
            /\ op' = [op EXCEPT ![c] = NoOp]
            /\ os' = [os EXCEPT ![c] = KillOS(@)]
            /\ Send(c, <<"canceled">>)
  /\ OpUnch

\* :resend (Ops.add/2, Shell handle_info(:resend, _))
OpResend(c) ==
  /\ op[c].resend /\ op[c].proc \in {"spawning", "running", "polling"}
  /\ op' = [op EXCEPT ![c].resend = FALSE]
  /\ Send(c, <<op[c].snap>>)
  /\ UNCHANGED os /\ OpUnch

\* :poll after reattaching: the exit file is checked first (background
\* children left in the group are killed), then whether the group lives.
Poll(c) ==
  /\ op[c].proc = "polling" /\ (os[c].exit \/ (os[c].cmd # "running" /\ ~os[c].bg))
  /\ op' = [op EXCEPT ![c] = NoOp]
  /\ IF os[c].exit
     THEN /\ os' = [os EXCEPT ![c] = KillOS(@)] /\ Send(c, <<"read", "completed">>)
     ELSE /\ Send(c, <<"failed">>) /\ UNCHANGED os
  /\ OpUnch

\* An op process crashes (restart: :temporary). terminate/2 kills the group
\* if the port is open and the pgid is known. The coordinator monitors its
\* operation processes: the :DOWN fails the operation (Session.op_down/3).
OpCrash(c) ==
  /\ cnt.opc < MaxOpCrash /\ op[c].proc # "none"
  /\ op' = [op EXCEPT ![c] = NoOp]
  /\ os' = IF op[c].proc = "running" THEN [os EXCEPT ![c] = KillOS(@)] ELSE os
  /\ Send(c, <<"failed">>)
  /\ cnt' = [cnt EXCEPT !.opc = @ + 1]
  /\ UNCHANGED <<log, cs, S, inq, tasks, nextTurn, nextCall, kind,
                 hubSent, connected, nodeUp, toolGone>>

(***************************************************************************)
(* Specification.                                                          *)
(***************************************************************************)
Init ==
  /\ log = <<>> /\ cs = "down" /\ S = DownS /\ inq = <<>> /\ opq = EmptyQs
  /\ tasks = {} /\ nextTurn = 1 /\ nextCall = 1
  /\ kind = [c \in Calls |-> "none"]
  /\ op = [c \in Calls |-> NoOp] /\ os = [c \in Calls |-> NoOS]
  /\ hubSent = {} /\ connected = TRUE /\ nodeUp = TRUE /\ toolGone = FALSE
  /\ cnt = [stops |-> 0, crash |-> 0, node |-> 0, opc |-> 0, disc |-> 0, dup |-> 0, hb |-> 0]

CoordNext ==
  \E mode \in Modes :
    \/ ContinueStep(mode) \/ InputStep(mode) \/ LLMStep(mode)
    \/ GraceStep(mode) \/ HBStep(mode) \/ \E c \in Calls : OpStep(mode, c)

OpNext ==
  \E c \in Calls :
    \/ OpInit(c) \/ OpSpawn(c) \/ OpCancelAck(c) \/ PidLine(c) \/ CmdExit(c)
    \/ BgExit(c) \/ PortExit(c) \/ OpCancel(c) \/ OpResend(c) \/ Poll(c) \/ OpCrash(c)

EnvNext ==
  \/ \E i \in ExtInputs : HubSend(i) \/ HubDup(i)
  \/ HubStop \/ Disconnect \/ Reconnect \/ NodeCrash \/ NodeBoot
  \/ ToolVanish \/ IdleFire \/ IdleStop \/ SupervisorRestart
  \/ \E t \in tasks : OrphanEnd(t)

Next == CoordNext \/ OpNext \/ EnvNext

\* What the implementation guarantees: messages get handled, timers fire,
\* the LLM call returns (after retries), op processes make progress, the
\* supervisor restarts a crashed coordinator, the node boots and rejoins.
Fairness ==
  /\ WF_vars(ContinueStep("ok")) /\ WF_vars(InputStep("ok")) /\ WF_vars(LLMStep("ok"))
  /\ WF_vars(GraceStep("ok")) /\ WF_vars(HBStep("ok"))
  /\ \A c \in Calls : WF_vars(OpStep("ok", c))
  /\ WF_vars(SupervisorRestart) /\ WF_vars(NodeBoot) /\ WF_vars(Reconnect)
  /\ WF_vars(IdleFire) /\ WF_vars(IdleStop)
  /\ \A c \in Calls : /\ WF_vars(OpInit(c)) /\ WF_vars(OpSpawn(c)) /\ WF_vars(OpCancelAck(c))
                      /\ WF_vars(PidLine(c)) /\ WF_vars(PortExit(c))
                      /\ WF_vars(OpCancel(c)) /\ WF_vars(OpResend(c)) /\ WF_vars(Poll(c))
  /\ WF_vars(\E t \in tasks : OrphanEnd(t))

\* Commands eventually exit on their own.
FairExit == \A c \in Calls : WF_vars(CmdExit(c))

Spec == Init /\ [][Next]_vars /\ Fairness /\ FairExit
\* Commands may run forever (servers, sleep 1e9): only a stop ends them.
SpecUnboundedCommands == Init /\ [][Next]_vars /\ Fairness

(***************************************************************************)
(* Safety properties.                                                      *)
(***************************************************************************)
TypeOK ==
  /\ cs \in {"down", "crashed", "init", "up"}
  /\ \A c \in Calls : op[c].proc \in {"none", "init", "await", "go", "cancelling",
                                      "spawning", "running", "polling"}
  /\ \A c \in Calls : os[c].cmd \in {"none", "running", "exited"}

\* Never two LLM requests in flight (counting orphaned tasks).
AtMostOneLLM == Cardinality(tasks) <= 1

\* A call's result is recorded at most once.
IsResult(r, c) == r.k = "status" /\ r.c = c /\ (r.st = "err" \/ r.sn \in Term)
OneResultPerCall ==
  \A c \in Calls : Cardinality({i \in 1..Len(log) : IsResult(log[i], c)}) <= 1

\* Replaying the log reproduces the live state (same environment).
ReplayMatches ==
  CoordLive =>
    \E Rp \in {Replay(log, S.avail)} :
      /\ Rp.available = S.available /\ Rp.delivered = S.delivered
      /\ Rp.turnInputs = S.turnInputs /\ Rp.turn = S.turn /\ Rp.busy = S.busy
      /\ Rp.calls = S.calls /\ Rp.ops = S.ops /\ Rp.seen = S.seen
      /\ Rp.ph = S.ph /\ Rp.real = S.real
      /\ \A c \in S.calls : Rp.cst[c] = S.cst[c]

\* Context: one real result per call; no turn with nothing to say; the
\* placeholder of a call in the grace set is never sent while grace runs.
ContextSound ==
  CoordLive => /\ ~S.dupReal /\ ~S.emptyTurn
               /\ \A c \in S.grace : "C" \notin S.ph[c]

\* The heartbeat is armed exactly while waiting only for tool calls.
HeartbeatArming ==
  cs = "up" => (S.hb = "armed" <=> (HBEnabled /\ S.llm = 0 /\ S.stop = "none"
                                    /\ S.available = S.delivered /\ S.calls # {}))

\* Each shell command is started at most once.
AtMostOnceExec == \A c \in Calls : os[c].execs <= 1

\* Scans of the log.
RECURSIVE QuietScan(_, _, _)
\* After "stopped", no turn until a new external input.
QuietScan(L, i, quiet) ==
  IF i > Len(L) THEN TRUE
  ELSE IF L[i].k = "turn" /\ quiet THEN FALSE
  ELSE QuietScan(L, i + 1,
         IF L[i].k = "state" /\ L[i].s = "stopped" THEN TRUE
         ELSE IF L[i].k = "input" /\ L[i].ik = "ext" THEN FALSE
         ELSE quiet)
StopQuiet == QuietScan(log, 1, FALSE)

RECURSIVE HonorScan(_, _, _)
\* Once a hard stop is logged, no turn starts before "stopped".
HonorScan(L, i, stopping) ==
  IF i > Len(L) THEN TRUE
  ELSE IF L[i].k = "turn" /\ stopping THEN FALSE
  ELSE HonorScan(L, i + 1,
         IF L[i].k = "input" /\ L[i].ik = "hard" THEN TRUE
         ELSE IF L[i].k = "state" /\ L[i].s = "stopped" THEN FALSE
         ELSE stopping)
StopHonored == HonorScan(log, 1, FALSE)

RECURSIVE SwallowScan(_, _, _, _)
\* An external input accepted while a hard stop is in progress is not
\* folded into that stop.
SwallowScan(L, i, stopping, after) ==
  IF i > Len(L) THEN TRUE
  ELSE IF L[i].k = "state" /\ L[i].s = "stopped" /\ after THEN FALSE
  ELSE SwallowScan(L, i + 1,
         IF L[i].k = "input" /\ L[i].ik = "hard" THEN TRUE
         ELSE IF L[i].k = "state" /\ L[i].s = "stopped" THEN FALSE
         ELSE stopping,
         IF L[i].k = "state" /\ L[i].s = "stopped" THEN FALSE
         ELSE IF L[i].k = "input" /\ L[i].ik = "ext" /\ stopping THEN TRUE
         ELSE IF L[i].k = "turn" THEN FALSE
         ELSE after)
InputDuringStopAnswered == SwallowScan(log, 1, FALSE, FALSE)

\* An "idle" record is only written when no LLM request, pending input,
\* tool call, or live operation exists.
IdleAppended ==
  /\ Len(log') > Len(log)
  /\ \E i \in (Len(log) + 1)..Len(log') : log'[i].k = "state" /\ log'[i].s = "idle"
\* (a) as the log tells it: nothing pending, no call, no live operation;
IdleLogSound ==
  [][IdleAppended =>
       \E Rp \in {Replay(log', S.avail)} :
         /\ Rp.available = Rp.delivered /\ Rp.calls = {}
         /\ \A c \in Calls : Rp.ops[c] \notin Live]_vars
\* (b) no LLM request of the session is running, orphans included.
IdleNoLLM == [][IdleAppended => tasks' = {}]_vars
\* ... and no operation process or command of the session is still alive.
IdlePhysical ==
  [][IdleAppended =>
       \A c \in Calls : op'[c].proc = "none" /\ os'[c].cmd # "running" /\ ~os'[c].bg]_vars

(***************************************************************************)
(* Liveness properties.                                                    *)
(***************************************************************************)
InputIdx(i) == {j \in 1..Len(log) : log[j].k = "input" /\ log[j].id = i}
\* A turn started after the input, and that turn got a model response.
Responded(i) ==
  \E b, d \in 1..Len(log) :
    /\ log[b].k = "turn" /\ log[d].k = "resp" /\ log[d].t = log[b].t
    /\ \E a \in InputIdx(i) : a < b
StoppedAfter(i) ==
  \E d \in 1..Len(log) : log[d].k = "state" /\ log[d].s = "stopped"
                         /\ \E a \in InputIdx(i) : a < d

\* Every external input is eventually followed by a model response, unless
\* a stop intervenes.
InputAnswered == \A i \in ExtInputs : (i \in hubSent) ~> (Responded(i) \/ StoppedAfter(i))

Scheduled(c) == \E j \in 1..Len(log) : log[j].k = "resp" /\ c \in log[j].cl
HasResult(c) == \E j \in 1..Len(log) : IsResult(log[j], c)
\* Every call the model made eventually gets a terminal result recorded.
CallResult == \A c \in Calls : Scheduled(c) ~> HasResult(c)

\* Every "running" record is eventually followed by "idle" or "stopped".
RunningSettles == (LastState(log) = "running") ~> (LastState(log) \in {"idle", "stopped"})

\* A hard stop the coordinator has accepted eventually completes ("stopped"
\* is logged after the stop), unless a crash or node crash forgets it.
Stopping == \E j \in 1..Len(log) :
              /\ log[j].k = "input" /\ log[j].ik = "hard"
              /\ ~\E d \in (j + 1)..Len(log) : log[d].k = "state" /\ log[d].s = "stopped"
Crashes == cnt.crash + cnt.node
StopCompletes ==
  \A n \in 0..(MaxCrash + MaxNodeCrash) :
    (CoordLive /\ S.stop # "none" /\ Crashes = n) ~> (~Stopping \/ Crashes > n)

(***************************************************************************)
(* Reachability witnesses: each should be violated (shows the situation   *)
(* is reachable, so the properties above are not passing vacuously).     *)
(***************************************************************************)
NoPlaceholderThenReal ==            \* a sent placeholder, then the real result
  CoordLive => ~\E c \in Calls : "C" \in S.ph[c] /\ S.real[c] # {}
NoPartialGrace ==                   \* grace still waiting after one call finished
  CoordLive => ~(Cardinality(S.grace) = 1 /\ \E c \in Calls : S.real[c] # {})
NoHeartbeat == ~\E j \in 1..Len(log) : log[j].k = "input" /\ log[j].ik = "hb"
NoSteer ==                          \* two turns with no response between them
  ~\E a, b \in 1..Len(log) :
     /\ a < b /\ log[a].k = "turn" /\ log[b].k = "turn"
     /\ ~\E d \in a..b : log[d].k = "resp"
NoCanceledStop ==                   \* a canceled op, then "stopped"
  ~\E a, b \in 1..Len(log) :
     /\ a < b /\ log[a].k = "status" /\ log[a].sn = "canceled"
     /\ log[b].k = "state" /\ log[b].s = "stopped"
NoErrorTurn ==                      \* an error status, then an immediate turn
  ~\E a \in 1..(Len(log) - 1) : log[a].k = "status" /\ log[a].st = "err"
                                 /\ \E b \in (a + 1)..Len(log) : log[b].k = "turn"

=============================================================================
