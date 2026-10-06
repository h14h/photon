------------------------------- MODULE Durable -------------------------------
(***************************************************************************)
(* The hub's durable agent harness (the Photon.Durable modules), with a    *)
(* machine tool (Photon.MachineTools.Call: shell and view_image) and the   *)
(* assistant's Routine, as implemented in apps/hub/lib after build step 1  *)
(* (Durable.md lists the findings and how they were fixed).  One           *)
(* conversation.                                                          *)
(*                                                                         *)
(* Granularity: every Store.commit is one atomic step (the Store runs     *)
(* commits one at a time, each in a DB transaction: Tx.run/1).  Work done  *)
(* outside a commit by a step process (reads, Machines.start/1, which is a *)
(* Store commit of its own, model calls) is a separate step, so other      *)
(* commits can interleave between them.  The scheduler's per-task commits  *)
(* are separate actions too; its stale snapshot only makes it more         *)
(* conservative (see Durable.md).                                          *)
(*                                                                         *)
(* The machine side is reduced to what the harness sees: the op row        *)
(* (Photon.Machines.Op: open, finished, closed, and its cancel flag) and   *)
(* its signal, with the node's result arriving at any time.  HubOps.tla   *)
(* models the protocol with the node.                                      *)
(*                                                                         *)
(* Paths in comments are relative to apps/hub/lib/photon/.  Code is cited  *)
(* by function: the scheduler's rules are Policy (durable/policy.ex), a    *)
(* generation's decisions Turn (durable/turn.ex), a tool call's ToolCall   *)
(* (durable/tool_call.ex), the inbox's Inbox (durable/inbox.ex), a machine *)
(* call's Call (machine_tools/call.ex) and its row's Machines.Rules        *)
(* (machines/rules.ex).                                                    *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS
    Users,          \* user submissions (Photon.Assistant.send), model values
    NTools,         \* tool-call task ids available to the model
    Routines,       \* routine task ids (strings); {} leaves routines out
    MaxRounds,      \* Turn.max_rounds/0 (60, in durable/turn.ex)
    MaxCalls,       \* most tool calls in one model response
    ToolTypes,      \* subset of {"machine", "plain"}
    GenPolicy,      \* "all_settled" (Turn.wait_for_tools/2) or "fail_fast" (what-if)
    LLMErrors,      \* model requests may fail ({:error, _} from LLM.stream)
    MachineOffline, \* a machine call may find its machine offline when it checks
    MaxRechecks,    \* per machine call: times its "until" may pass (the minute
                    \*   rechecks); after that it wakes only on its signal
    MaxHubCrashes,  \* whole-hub crashes (BEAM dies; DB survives)
    MaxSchedCrashes,\* Scheduler-process-only crashes (supervisor restarts it)
    MaxStepCrashes, \* step processes that exit abnormally, or tool code that
                    \*   raises (ToolTask rescues it as an error result)
    MaxAborts       \* user Stop presses (Durable.abort/1)

ASSUME MaxRounds >= 1 /\ MaxCalls >= 1 /\ NTools >= 0 /\ MaxRechecks >= 0
ASSUME ToolTypes \subseteq {"machine", "plain"} /\ ToolTypes # {}
ASSUME GenPolicy \in {"all_settled", "fail_fast"}

-----------------------------------------------------------------------------
(* Identifiers.  Ids are deterministic so the state space stays small:    *)
(* tool task i is "t<i>", and a machine call's op row and signal are keyed *)
(* by its task (the op ID is derived from the task ID, Wait.op_id/1).  A   *)
(* routine r posts the submission "rs_<r>".                               *)

ToolAt(i)  == "t" \o ToString(i)
ToolIds    == {ToolAt(i) : i \in 1..NTools}
RS(r)      == "rs_" \o r
SubIds     == Users \cup {RS(r) : r \in Routines}
\* A generation is only created by submit_tx placing a new submission while
\* idle (Durable.submit_tx/4, Inbox.submit_action/3), so there are never more
\* of them than submissions.
NGen       == Cardinality(SubIds)
GenAt(i)   == "g" \o ToString(i)
GenIds     == {GenAt(i) : i \in 1..NGen}
TaskIds    == GenIds \cup ToolIds \cup Routines

Kind(id) == CASE id \in GenIds   -> "gen"
              [] id \in ToolIds  -> "tool"
              [] OTHER           -> "routine"

Terminal == {"done", "failed", "aborted"}            \* TaskRecord.terminal_statuses/0
FinPcs   == {"fin_err", "fin_ok", "fin_int"}

VARIABLES
    task,         \* tasks table (task_record.ex); status "none" = not created
    sub,          \* submissions table (submission.ex); status "none" = not created
    toolResults,  \* number of "tool_result" entries for tool task t
    orphanCalls,  \* tool calls in "assistant" entries that never got a tool task
    nextGen, nextTool, nextOrd,   \* id allocation; nextOrd = inserted_at order
    row,          \* machine_ops row of t's op: "none", "open", "finished", "closed"
    rcx,          \* its `cancel` flag
    signal,       \* signals table: signal[t] <=> "op:<op_id>" recorded (in the
                  \*   commit that moves the row out of "open")
    claims,       \* times t's finished row was claimed into a tool result
    opResult,     \* t's tool result carries its op's result
    execCount,    \* times an unsafe ("plain") tool actually executed
    untilPassed,  \* the deadline ("until") of task id's current wait has passed
    rechecks,     \* per machine call: times it parked again (bounded, see MaxRechecks)
    steps,        \* live step processes under Durable.TaskSupervisor
    inc,          \* Scheduler incarnation (bumped by a Scheduler-only crash)
    hubCrashes, schedCrashes, stepCrashes, aborts

dbVars    == <<task, sub, toolResults, orphanCalls, nextGen, nextTool, nextOrd>>
rowVars   == <<row, rcx, signal>>
ghostVars == <<claims, opResult, execCount>>
timeVars  == <<untilPassed, rechecks>>
procVars  == <<steps, inc>>
faultVars == <<hubCrashes, schedCrashes, stepCrashes, aborts>>
vars      == <<dbVars, rowVars, ghostVars, timeVars, procVars, faultVars>>

-----------------------------------------------------------------------------
(* Records *)

\* tok: which start of the task this is (Tx.transition/4 fences on the
\* updated_at the step started with; only a new start or an abort changes
\* a running task).  off: a machine call's "offline_since" is set (its
\* parked state, Call.park/4 and Wait.next/4).
NoTask(id) ==
    [status |-> "none", phase |-> "none", runs |-> 0, tok |-> 0, abort |-> FALSE,
     owner |-> "none", bg |-> Kind(id) = "routine",
     wOn |-> {}, wSig |-> "none", wUntil |-> FALSE,
     subs |-> {}, rounds |-> 0, ttype |-> "none", off |-> FALSE]

\* submit_tx's generation (Durable.submit_tx/4, Inbox.run/2)
NewGen(id, s) == [NoTask(id) EXCEPT !.status = "pending", !.phase = "request",
                                    !.subs = {s}]

\* answered/4 creates one tool task per call (Generation.follow/5, Turn.tool_task/2)
NewTool(id, g, ty) == [NoTask(id) EXCEPT !.status = "pending", !.phase = "run",
                                         !.owner = g, !.ttype = ty]

NoSub == [status |-> "none", mode |-> "none", ord |-> 0]

-----------------------------------------------------------------------------
(* Operations inside one commit (Photon.Durable.Tx).  They take the       *)
(* in-transaction table and return the new one, so they compose.          *)

LiveIn(tk, id) == tk[id].status \notin Terminal \cup {"none"}

\* Tx.live_owned + "not child.background" (Tx.request_abort/3, Tx.finish/4)
FgKids(tk, id) == {c \in TaskIds : tk[c].owner = id /\ ~tk[c].bg /\ LiveIn(tk, c)}

\* Tx.request_abort/3: marks the task and, recursively, its live
\* foreground children.  A terminal task is left alone.
RECURSIVE Marked(_, _)
Marked(tk, id) == IF ~LiveIn(tk, id) THEN {}
                  ELSE {id} \cup UNION {Marked(tk, c) : c \in FgKids(tk, id)}

ReqAbortSet(tk, ids) ==
    LET m == UNION {Marked(tk, i) : i \in ids}
    IN  [x \in TaskIds |-> IF x \in m THEN [tk[x] EXCEPT !.abort = TRUE] ELSE tk[x]]

ReqAbort(tk, id) == ReqAbortSet(tk, {id})

\* Tx.active_run/2 (Queries.active_run/1): unfinished, conversation-owned, foreground
ActiveRunsIn(tk) == {id \in TaskIds : tk[id].owner = "none" /\ ~tk[id].bg /\ LiveIn(tk, id)}
IdleIn(tk) == ActiveRunsIn(tk) = {}

\* Tx.finish/4: abort live foreground children, then finish
FinishIn(tk, id, st) ==
    LET tk1 == ReqAbortSet(tk, FgKids(tk, id))
    IN  [tk1 EXCEPT ![id].status = st, ![id].wOn = {}, ![id].wSig = "none",
                    ![id].wUntil = FALSE]

\* Tx.apply_transition {:next, phase, cp}
NextIn(tk, id, ph, ss, rd) ==
    [tk EXCEPT ![id].status = "pending", ![id].phase = ph,
               ![id].runs = IF ph = tk[id].phase THEN tk[id].runs ELSE 0,
               ![id].wOn = {}, ![id].wSig = "none", ![id].wUntil = FALSE,
               ![id].subs = ss, ![id].rounds = rd]

\* Tx.apply_transition {:wait, waiting, phase, cp}
WaitIn(tk, id, on, sg, un, ph, ss, rd) ==
    [tk EXCEPT ![id].status = "waiting", ![id].phase = ph, ![id].runs = 0,
               ![id].wOn = on, ![id].wSig = sg, ![id].wUntil = un,
               ![id].subs = ss, ![id].rounds = rd]

\* A machine call parks (ToolCall.park/2 with Call.wait/2): on its op's
\* signal and a recheck time, in phase "resume", with offline_since.
Park(tk, t, off) == [WaitIn(tk, t, {}, t, TRUE, "resume", {}, 0) EXCEPT ![t].off = off]

\* Tx.transition/4 ignores a task that finished or was marked for abort
\* meanwhile, and a step that is no longer the task's current start (its
\* task was reset and started again after a scheduler restart: status not
\* running, or a later start); Runtime.commit then rolls the whole commit
\* back.
Ignored(st) ==
    LET id == st.t IN
    \/ task[id].status \in Terminal \/ task[id].abort
    \/ task[id].status # "running" \/ task[id].tok # st.tok

\* Machines.cancel_tx/2 (Rules.on_cancel/2, hub rule 7): an open row gets
\* `cancel` (and op.cancel, which this spec leaves to HubOps.tla); a
\* finished one closes and drops the result nobody will claim.  Closed rows
\* and missing ones are left alone, so it is a no-op for plain tools.
CancelRow(t) ==
    /\ row' = [row EXCEPT ![t] = IF @ = "finished" THEN "closed" ELSE @]
    /\ rcx' = [rcx EXCEPT ![t] = @ \/ row[t] = "open"]

\* Submissions
Queued(sb)    == {x \in SubIds : sb[x].status = "queued"}
Oldest(sb, q) == CHOOSE x \in q : \A y \in q : sb[x].ord <= sb[y].ord
Place(sb, ss) == [x \in SubIds |-> IF x \in ss THEN [sb[x] EXCEPT !.status = "placed"]
                                   ELSE sb[x]]
\* Generation.settle/4 (Turn.settlement/2): only "placed" ones
Settle(sb, ss, st) ==
    [x \in SubIds |-> IF x \in ss /\ sb[x].status = "placed"
                      THEN [sb[x] EXCEPT !.status = st] ELSE sb[x]]
\* Generation.continue_with_inbox/3 (Inbox.next_input/1): all queued steers, else the
\* oldest queued input
NextInput(sb) ==
    LET q == Queued(sb)
        steers == {x \in q : sb[x].mode = "steer"}
    IN  IF steers # {} THEN steers ELSE IF q = {} THEN {} ELSE {Oldest(sb, q)}

\* Durable.submit_tx/4, inside a commit whose task table
\* so far is tk.  A known request id returns the existing submission; busy
\* queues; idle places it and creates a generation.  (when_busy "reject"
\* only rolls back and is left out.)
SubNew(sb, s) == sb[s].status = "none"
StartsRun(tk, sb, s) == SubNew(sb, s) /\ IdleIn(tk)
SubmitTk(tk, sb, s) ==
    IF StartsRun(tk, sb, s) THEN [tk EXCEPT ![GenAt(nextGen)] = NewGen(GenAt(nextGen), s)]
    ELSE tk
SubmitSb(tk, sb, s, mode) ==
    IF ~SubNew(sb, s) THEN sb
    ELSE [sb EXCEPT ![s] = [status |-> IF IdleIn(tk) THEN "placed" ELSE "queued",
                            mode |-> mode, ord |-> nextOrd]]
SubmitGen(tk, sb, s) == IF StartsRun(tk, sb, s) THEN nextGen + 1 ELSE nextGen
SubmitOrd(sb, s)     == IF SubNew(sb, s) THEN nextOrd + 1 ELSE nextOrd

\* Durable.continue_inbox/2: after a conversation's run fails or is aborted
\* (Scheduler.fail, stop_aborted), the inbox's next input (every queued
\* steer, else the oldest) starts a new run.  Only for a run: background
\* tasks and tasks with an owner leave the inbox alone.
HandOff(id, tk, sb) ==
    LET nxt == NextInput(sb) IN
    IF Kind(id) = "gen" /\ IdleIn(tk) /\ nxt # {}
    THEN <<[tk EXCEPT ![GenAt(nextGen)] = [NewGen(GenAt(nextGen), "none") EXCEPT !.subs = nxt]],
           Place(sb, nxt), nextGen + 1>>
    ELSE <<tk, sb, nextGen>>

-----------------------------------------------------------------------------
(* Step processes.  A step is spawned by Scheduler.start/2 (spawn_step/1) *)
(* with the task as it was then: phase, runs, checkpoint.  pc              *)
(* "exited" = the process has returned; the Scheduler has not yet handled  *)
(* its result message.                                                     *)

CurSteps(id) == {st \in steps : st.t = id /\ st.inc = inc}

\* A step that returns after its commit moved the task out of "running" needs
\* nothing more from the Scheduler (its handle_info just forgets the step), so
\* it is dropped at once: StepDone.  A step that returns (or dies) while its task
\* is still "running" stays as "exited" until the Scheduler handles its result
\* or :DOWN (SchedExit).  A step of an older Scheduler incarnation sends its
\* result to a dead pid, so it is just dropped.
StepDone(st)   == steps \ {st}
ExitSet(st)    == IF st.inc = inc /\ task[st.t].status = "running"
                  THEN {[st EXCEPT !.pc = "exited"]} ELSE {}
StepTo(st, pc) == (steps \ {st}) \cup {[st EXCEPT !.pc = pc]}
StepExit(st)   == (steps \ {st}) \cup ExitSet(st)

\* A Runtime.commit that came back :ignored: nothing is written.
IgnoredCommit(st) ==
    /\ steps' = StepExit(st)
    /\ UNCHANGED <<dbVars, rowVars, ghostVars, timeVars, inc, faultVars>>

---------------------------------------------------------------------------
(* Generation (durable/generation.ex, decisions in durable/turn.ex) *)

\* step("request"): one model request (no commit), then one Runtime.commit of
\* answered/4 or of the failure (Generation.commit_result/4).  The model's answer is
\* chosen at commit time; nothing between the call and the commit depends on it.
GenRequest(st) ==
    LET g == st.t IN
    /\ Kind(g) = "gen" /\ st.pc = "go" /\ st.phase = "request"
    /\ IF Ignored(st) THEN IgnoredCommit(st)
       ELSE
       /\ steps' = StepDone(st)
       /\ UNCHANGED <<toolResults, rowVars, ghostVars, timeVars, inc, faultVars>>
       /\ \/ \* answer without tool calls: settle "done", continue with the
             \* inbox (Generation.follow/5, continue_with_inbox/3)
             LET sb1 == Settle(sub, st.subs, "done")
                 nxt == NextInput(sb1)
             IN  /\ sub' = Place(sb1, nxt)
                 /\ task' = IF nxt = {} THEN FinishIn(task, g, "done")
                            ELSE NextIn(task, g, "request", nxt, 0)
                 /\ UNCHANGED <<orphanCalls, nextGen, nextTool, nextOrd>>
          \/ \* {:error, _}: error entry, settle "unanswered", then go on
             \* with the inbox like an answered run, or {:fail, _}
             \* (Generation.step("request"), continue_with_inbox/3)
             /\ LLMErrors
             /\ LET sb1 == Settle(sub, st.subs, "unanswered")
                    nxt == NextInput(sb1)
                IN  /\ sub' = Place(sb1, nxt)
                    /\ task' = IF nxt = {} THEN FinishIn(task, g, "failed")
                               ELSE NextIn(task, g, "request", nxt, 0)
             /\ UNCHANGED <<orphanCalls, nextGen, nextTool, nextOrd>>
          \/ \* tool calls (Turn.outcome/2, Generation.follow/5)
             \E k \in 1..MaxCalls :
                IF st.rounds + 1 < MaxRounds
                THEN \* one tool task per call, then wait on all of them
                     /\ nextTool + k - 1 <= NTools
                     /\ \E types \in [1..k -> ToolTypes] :
                        LET ids == {ToolAt(nextTool + i - 1) : i \in 1..k}
                            ix(x) == CHOOSE i \in 1..k : ToolAt(nextTool + i - 1) = x
                            tk1 == [x \in TaskIds |-> IF x \in ids
                                                      THEN NewTool(x, g, types[ix(x)])
                                                      ELSE task[x]]
                        IN  task' = WaitIn(tk1, g, ids, "none", FALSE, "after_tools",
                                           st.subs, st.rounds + 1)
                     /\ nextTool' = nextTool + k
                     /\ UNCHANGED <<sub, orphanCalls, nextGen, nextOrd>>
                ELSE \* too many rounds: the assistant entry with the calls is
                     \* stored, each call gets a "Not run" tool_result in the
                     \* same commit, and the run goes on with the inbox or
                     \* fails like a failed request
                     /\ LET sb1 == Settle(sub, st.subs, "unanswered")
                            nxt == NextInput(sb1)
                        IN  /\ sub' = Place(sb1, nxt)
                            /\ task' = IF nxt = {} THEN FinishIn(task, g, "failed")
                                       ELSE NextIn(task, g, "request", nxt, 0)
                     /\ UNCHANGED <<orphanCalls, nextGen, nextTool, nextOrd>>

\* step("after_tools"): place queued steers, request again (Turn.after_tools/2)
GenAfterTools(st) ==
    LET g == st.t
        steers == {x \in Queued(sub) : sub[x].mode = "steer"}
    IN
    /\ Kind(g) = "gen" /\ st.pc = "go" /\ st.phase = "after_tools"
    /\ IF Ignored(st) THEN IgnoredCommit(st)
       ELSE /\ sub' = Place(sub, steers)
            /\ task' = NextIn(task, g, "request", st.subs \cup steers, st.rounds)
            /\ steps' = StepDone(st)
            /\ UNCHANGED <<toolResults, orphanCalls, nextGen, nextTool, nextOrd,
                           rowVars, ghostVars, timeVars, inc, faultVars>>

---------------------------------------------------------------------------
(* ToolTask (durable/tool_task.ex, durable/tool_call.ex) with the         *)
(* assistant's tools.                                                       *)
(* "machine" = shell / view_image (Call, replay :safe, parks on its op).   *)
(* "plain" = a tool with the default replay :unsafe that runs and returns. *)

IsMachine(st) == Kind(st.t) = "tool" /\ task[st.t].ttype = "machine"

Offline == IF MachineOffline THEN BOOLEAN ELSE {FALSE}

\* Call.execute/3 up to Machines.start/1 (a rerun that finds the row skips
\* the machine check).  Machines.start/1 is a Store commit of its own, not
\* the step's, so the start token doesn't fence it: it inserts the row only
\* while the task is unfinished and not marked for abort (hub rule 9,
\* Rules.insert?/2), and only once (on_conflict: :nothing).  Otherwise the
\* call ends with "stopped before it reached" (an error result).
MStart(st) ==
    LET t == st.t IN
    /\ IsMachine(st) /\ st.phase = "run" /\ st.pc = "go"
    /\ IF LiveIn(task, t) /\ ~task[t].abort
       THEN /\ row' = IF row[t] = "none" THEN [row EXCEPT ![t] = "open"] ELSE row
            /\ steps' = StepTo(st, "park")
       ELSE /\ steps' = StepTo(st, "fin_err")
            /\ UNCHANGED row
    /\ UNCHANGED <<dbVars, rcx, signal, ghostVars, timeVars, inc, faultVars>>

\* {:wait, %{"signal" => "op:<id>", "until" => ...}, state} committed by
\* Runtime.transition (ToolCall.park/2), with offline_since if the machine
\* is offline now (Wait.first/3).
MPark(st) ==
    LET t == st.t IN
    /\ IsMachine(st) /\ st.pc = "park"
    /\ IF Ignored(st) THEN IgnoredCommit(st)
       ELSE \E off \in Offline :
            /\ task' = Park(task, t, off)
            /\ untilPassed' = [untilPassed EXCEPT ![t] = FALSE]
            /\ steps' = StepDone(st)
            /\ UNCHANGED <<sub, toolResults, orphanCalls, nextGen, nextTool, nextOrd,
                           rowVars, ghostVars, rechecks, inc, faultVars>>

\* Call.resume/2 reads the row (Machines.op_state/1) and, for an open one,
\* whether the machine is online, then decides with Wait.next/4: finished
\* -> claim; open -> park again (online: after Machines.repush/1, which
\* only asks the channel; offline: with offline_since), or give up once
\* the machine has been offline past the limit (only after an earlier
\* offline sighting: time is abstract); closed or missing -> an error.
MResume(st) ==
    LET t == st.t
        choices ==
          CASE row[t] = "finished" -> {"claim"}
            [] row[t] = "open" ->
                 {"repark_on"} \cup
                 (IF MachineOffline
                  THEN {"repark_off"} \cup (IF st.off THEN {"abandon"} ELSE {})
                  ELSE {})
            [] OTHER -> {"fin_err"}
    IN
    /\ IsMachine(st) /\ st.phase = "resume" /\ st.pc = "go"
    /\ \E nxt \in choices : steps' = StepTo(st, nxt)
    /\ UNCHANGED <<dbVars, rowVars, ghostVars, timeVars, inc, faultVars>>

\* Park again: Runtime.transition with {:wait, ...}.
MRepark(st) ==
    LET t == st.t IN
    /\ IsMachine(st) /\ st.pc \in {"repark_on", "repark_off"}
    /\ IF Ignored(st) THEN IgnoredCommit(st)
       ELSE /\ task' = Park(task, t, st.pc = "repark_off")
            /\ untilPassed' = [untilPassed EXCEPT ![t] = FALSE]
            /\ rechecks' = [rechecks EXCEPT ![t] = @ + 1]
            /\ steps' = StepDone(st)
            /\ UNCHANGED <<sub, toolResults, orphanCalls, nextGen, nextTool, nextOrd,
                           rowVars, ghostVars, inc, faultVars>>

\* {:commit, fun} from Call.resume/2: the commit that records the result
\* decides on the row as it is then.  claim_tx/2 (and abandon_tx/2, for a
\* row that finished meanwhile) closes a finished row and returns its
\* result (hub rule 8).  Otherwise the result is an error ("already
\* delivered", or the offline message) and the row is canceled as
\* cancel_tx/2 does it (hub rules 7 and 10).  An aborted call's commit is
\* ignored whole.
MClaim(st) ==
    LET t == st.t IN
    /\ IsMachine(st) /\ st.pc \in {"claim", "abandon"}
    /\ IF Ignored(st) THEN IgnoredCommit(st)
       ELSE /\ toolResults' = [toolResults EXCEPT ![t] = @ + 1]
            /\ task' = FinishIn(task, t, "done")
            /\ steps' = StepDone(st)
            /\ IF row[t] = "finished"
               THEN /\ row' = [row EXCEPT ![t] = "closed"]
                    /\ claims' = [claims EXCEPT ![t] = @ + 1]
                    /\ opResult' = [opResult EXCEPT ![t] = TRUE]
                    /\ UNCHANGED rcx
               ELSE /\ CancelRow(t)
                    /\ UNCHANGED <<claims, opResult>>
            /\ UNCHANGED <<sub, orphanCalls, nextGen, nextTool, nextOrd, signal,
                           execCount, timeVars, inc, faultVars>>

\* A plain tool with replay :unsafe: a rerun (runs > 1) reports
\* "interrupted" instead of executing again (ToolCall.plan/3).
PlainRun(st) ==
    LET t == st.t IN
    /\ Kind(t) = "tool" /\ task[t].ttype = "plain" /\ st.phase = "run" /\ st.pc = "go"
    /\ IF st.runs > 1
       THEN /\ steps' = StepTo(st, "fin_int")
            /\ UNCHANGED execCount
       ELSE /\ execCount' = [execCount EXCEPT ![t] = @ + 1]
            /\ steps' = StepTo(st, "fin_ok")
    /\ UNCHANGED <<dbVars, rowVars, claims, opResult, timeVars, inc, faultVars>>

\* ToolTask.finish: the tool_result entry and {:done} in one Runtime.commit.
\* A machine call's error result cancels its op in the same commit
\* (Call.fail/2 -> cancel_tx/2, hub rule 10), and so does the commit that
\* records a raise ToolTask rescued (ToolTask.raised/3 runs on_interrupt/2).
\* For a plain tool there is no row, so CancelRow changes nothing.
ToolFinish(st) ==
    LET t == st.t IN
    /\ Kind(t) = "tool" /\ st.pc \in FinPcs
    /\ IF Ignored(st) THEN IgnoredCommit(st)
       ELSE /\ toolResults' = [toolResults EXCEPT ![t] = @ + 1]
            /\ task' = FinishIn(task, t, "done")
            /\ steps' = StepDone(st)
            /\ CancelRow(t)
            /\ UNCHANGED <<sub, orphanCalls, nextGen, nextTool, nextOrd, signal,
                           ghostVars, timeVars, inc, faultVars>>

---------------------------------------------------------------------------
(* Routine (assistant/routine.ex) *)

\* step("start"): sleep until first_at (Routine.first_wait/1)
RoutineStart(st) ==
    LET r == st.t IN
    /\ Kind(r) = "routine" /\ st.phase = "start" /\ st.pc = "go"
    /\ IF Ignored(st) THEN IgnoredCommit(st)
       ELSE /\ task' = WaitIn(task, r, {}, "none", TRUE, "fire", {}, 0)
            /\ untilPassed' = [untilPassed EXCEPT ![r] = FALSE]
            /\ steps' = StepDone(st)
            /\ UNCHANGED <<sub, toolResults, orphanCalls, nextGen, nextTool, nextOrd,
                           rowVars, ghostVars, rechecks, inc, faultVars>>

\* step("fire") of a one-off routine: submit_tx + {:done} (Routine.after_fire/2)
RoutineFire(st) ==
    LET r == st.t
        s == RS(r)
    IN
    /\ Kind(r) = "routine" /\ st.phase = "fire" /\ st.pc = "go"
    /\ IF Ignored(st) THEN IgnoredCommit(st)
       ELSE /\ task' = FinishIn(SubmitTk(task, sub, s), r, "done")
            /\ sub' = SubmitSb(task, sub, s, "follow_up")
            /\ nextGen' = SubmitGen(task, sub, s)
            /\ nextOrd' = SubmitOrd(sub, s)
            /\ steps' = StepDone(st)
            /\ UNCHANGED <<toolResults, orphanCalls, nextTool, rowVars, ghostVars,
                           timeVars, inc, faultVars>>

StepAct(st) ==
    \/ GenRequest(st) \/ GenAfterTools(st)
    \/ MStart(st) \/ MPark(st) \/ MResume(st) \/ MRepark(st) \/ MClaim(st)
    \/ PlainRun(st) \/ ToolFinish(st)
    \/ RoutineStart(st) \/ RoutineFire(st)

---------------------------------------------------------------------------
(* Scheduler (durable/scheduler.ex, rules in durable/policy.ex).  Each    *)
(* per-task commit of reconcile is its own action.                         *)

\* start_pending/1 and start/2: pending -> running, runs + 1 (Policy.start/1),
\* spawn the step.  Skipped while this Scheduler still has a step for the task
\* (Policy.start_action/4).
SchedStart(id) ==
    /\ task[id].status = "pending" /\ ~task[id].abort
    /\ CurSteps(id) = {}
    /\ task' = [task EXCEPT ![id].status = "running", ![id].runs = @ + 1, ![id].tok = @ + 1]
    /\ steps' = steps \cup {[t |-> id, inc |-> inc, pc |-> "go", tok |-> task[id].tok + 1,
                             phase |-> task[id].phase, runs |-> task[id].runs + 1,
                             subs |-> task[id].subs, rounds |-> task[id].rounds,
                             off |-> task[id].off]}
    /\ UNCHANGED <<sub, toolResults, orphanCalls, nextGen, nextTool, nextOrd,
                   rowVars, ghostVars, timeVars, inc, faultVars>>

\* Scheduler.wake?/2 and Policy.wake?/3 (its on_ready?/3); a missing task counts
\* as done
OnReady(id) ==
    \/ \A c \in task[id].wOn : task[c].status \in Terminal \cup {"none"}
    \/ GenPolicy = "fail_fast" /\ \E c \in task[id].wOn : task[c].status \in {"failed", "aborted"}

WakeReady(id) ==
    LET w == task[id] IN
    \/ w.wOn = {} /\ w.wSig = "none" /\ ~w.wUntil
    \/ w.wOn # {} /\ OnReady(id)
    \/ w.wSig # "none" /\ signal[w.wSig]
    \/ w.wUntil /\ untilPassed[id]

\* Scheduler.fail_fast/2 and Policy.fail_fast_aborts/2
FailFastIn(tk, id) ==
    IF GenPolicy = "fail_fast" /\ \E c \in tk[id].wOn : tk[c].status \in {"failed", "aborted"}
    THEN ReqAbortSet(tk, {c \in tk[id].wOn : LiveIn(tk, c)})
    ELSE tk

\* Scheduler.wake_waiting/2 (Policy.wakeable?/1 before and inside the commit)
SchedWake(id) ==
    /\ task[id].status = "waiting" /\ ~task[id].abort
    /\ WakeReady(id)
    /\ task' = [FailFastIn(task, id) EXCEPT ![id].status = "pending"]
    /\ UNCHANGED <<sub, toolResults, orphanCalls, nextGen, nextTool, nextOrd,
                   rowVars, ghostVars, timeVars, procVars, faultVars>>

\* stop_aborted/2, first half: terminate_child for a marked task whose step
\* this Scheduler is running (Policy.steps_to_kill/2).  A step that already
\* returned (result not yet handled) is not found, so nothing happens to it.
SchedKill(id) ==
    /\ task[id].abort /\ LiveIn(task, id)
    /\ \E st \in CurSteps(id) : st.pc # "exited" /\ steps' = steps \ {st}
    /\ UNCHANGED <<dbVars, rowVars, ghostVars, timeVars, inc, faultVars>>

\* on_abort/on_fail hooks run in the commit that ends the task that way.
\* Generation settles its submissions; ToolTask records the result, and a
\* machine call's on_interrupt/2 cancels its op (Call.on_interrupt/2 ->
\* cancel_tx/2).
OnAbortSb(id, sb) ==
    IF Kind(id) = "gen" THEN Settle(sb, task[id].subs, "unanswered") ELSE sb
OnAbortTr(id) ==
    IF Kind(id) = "tool" THEN [toolResults EXCEPT ![id] = @ + 1] ELSE toolResults
OnAbortRow(id) == IF Kind(id) = "tool" THEN CancelRow(id) ELSE UNCHANGED <<row, rcx>>

\* stop_aborted/2, second half: a marked task with no live foreground work is
\* aborted, bottom-up (Policy.ready_to_abort/1, Scheduler.abort_tx/2).  Its kills come first.
SchedAbort(id) ==
    /\ task[id].abort /\ LiveIn(task, id)
    /\ FgKids(task, id) = {}
    /\ ~\E st \in CurSteps(id) : st.pc # "exited"
    /\ LET r == HandOff(id, [task EXCEPT ![id].status = "aborted", ![id].wOn = {},
                                         ![id].wSig = "none", ![id].wUntil = FALSE],
                        OnAbortSb(id, sub))
       IN  /\ task' = r[1] /\ sub' = r[2] /\ nextGen' = r[3]
    /\ toolResults' = OnAbortTr(id)
    /\ OnAbortRow(id)
    /\ UNCHANGED <<orphanCalls, nextTool, nextOrd, signal, ghostVars, timeVars,
                   procVars, faultVars>>

\* A step's result or :DOWN: if the task is still "running" the step ended
\* without a transition (or crashed), so it fails (Scheduler.fail/2 with
\* on_fail), unless it is marked for abort, which stop_aborted then
\* finishes as aborted.  A step killed by stop_aborted never gets here (it
\* is in state.killed).  No task kind asks for a retry any more (on_fail/3
\* returning :retry was NodeWatch's).
SchedExit(st) ==
    /\ st \in steps /\ st.inc = inc /\ st.pc = "exited"
    /\ steps' = steps \ {st}
    /\ IF task[st.t].status = "running" /\ ~task[st.t].abort
       THEN /\ LET r == HandOff(st.t, FinishIn(task, st.t, "failed"), OnAbortSb(st.t, sub))
               IN  /\ task' = r[1] /\ sub' = r[2] /\ nextGen' = r[3]
            /\ toolResults' = OnAbortTr(st.t)
            /\ OnAbortRow(st.t)
            /\ UNCHANGED <<orphanCalls, nextTool, nextOrd, signal>>
       ELSE UNCHANGED <<dbVars, rowVars>>
    /\ UNCHANGED <<ghostVars, timeVars, inc, faultVars>>

---------------------------------------------------------------------------
(* The user, the machine, and time *)

\* Photon.Assistant.send -> Durable.submit (Assistant.send/2, Durable.submit/3)
UserSubmit(u) ==
    /\ sub[u].status = "none"
    /\ \E mode \in {"follow_up", "steer"} :
         /\ task' = SubmitTk(task, sub, u)
         /\ sub' = SubmitSb(task, sub, u, mode)
         /\ nextGen' = SubmitGen(task, sub, u)
         /\ nextOrd' = SubmitOrd(sub, u)
    /\ UNCHANGED <<toolResults, orphanCalls, nextTool, rowVars, ghostVars, timeVars,
                   procVars, faultVars>>

\* Assistant.stop -> Durable.abort/2: withdraw the user's queued input
\* (routine prompts stay, Assistant.background_input?/1), mark the run.
UserAbort ==
    /\ aborts < MaxAborts
    /\ aborts' = aborts + 1
    /\ sub' = [x \in SubIds |-> IF sub[x].status = "queued" /\ x \in Users
                                THEN [sub[x] EXCEPT !.status = "withdrawn"] ELSE sub[x]]
    /\ task' = IF IdleIn(task) THEN task
               ELSE ReqAbort(task, CHOOSE r \in ActiveRunsIn(task) : TRUE)
    /\ UNCHANGED <<toolResults, orphanCalls, nextGen, nextTool, nextOrd, rowVars,
                   ghostVars, timeVars, procVars, hubCrashes, schedCrashes, stepCrashes>>

\* The machine's terminal snapshot: Machines.snapshot/3 with
\* Rules.on_snapshot/3 (hub rule 4) in one Store commit: an open row
\* becomes finished with the result, or closed if it was canceled, and the
\* op's signal fires.  The node may report at any time once the row exists.
OpFinish(t) ==
    /\ row[t] = "open"
    /\ row' = [row EXCEPT ![t] = IF rcx[t] THEN "closed" ELSE "finished"]
    /\ signal' = [signal EXCEPT ![t] = TRUE]
    /\ UNCHANGED <<dbVars, rcx, ghostVars, timeVars, procVars, faultVars>>

\* A waiting task's deadline passes; the Scheduler's timer (arm_timer/1,
\* Policy.timer_delay/2) then reconciles.  A machine call's rechecks are
\* bounded (MaxRechecks).
Tick(id) ==
    /\ task[id].status = "waiting" /\ task[id].wUntil /\ ~untilPassed[id]
    /\ Kind(id) = "tool" => rechecks[id] < MaxRechecks
    /\ untilPassed' = [untilPassed EXCEPT ![id] = TRUE]
    /\ UNCHANGED <<dbVars, rowVars, ghostVars, rechecks, procVars, faultVars>>

---------------------------------------------------------------------------
(* Faults *)

RunningToPending ==
    [id \in TaskIds |-> IF task[id].status = "running"
                        THEN [task[id] EXCEPT !.status = "pending"] ELSE task[id]]

\* The hub dies between any two steps: processes are gone, the DB stays.
\* Boot: Scheduler.init puts running tasks back to pending.
HubCrash ==
    /\ hubCrashes < MaxHubCrashes
    /\ hubCrashes' = hubCrashes + 1
    /\ steps' = {}
    /\ task' = RunningToPending
    /\ UNCHANGED <<sub, toolResults, orphanCalls, nextGen, nextTool, nextOrd,
                   rowVars, ghostVars, timeVars, inc, schedCrashes, stepCrashes, aborts>>

\* Only the Scheduler process dies; its supervisor (Durable.Supervisor,
\* one_for_one) restarts it.  Steps run under the separate Durable.TaskSupervisor via
\* async_nolink, so they keep running; init resets every running task to
\* pending, and the old steps' commits are fenced out (Ignored), but not
\* Machines.start/1's own commit (hub rule 9 guards that one).
SchedCrash ==
    /\ schedCrashes < MaxSchedCrashes
    /\ schedCrashes' = schedCrashes + 1
    /\ inc' = inc + 1
    /\ steps' = {st \in steps : st.pc # "exited"}
    /\ task' = RunningToPending
    /\ UNCHANGED <<sub, toolResults, orphanCalls, nextGen, nextTool, nextOrd,
                   rowVars, ghostVars, timeVars, hubCrashes, stepCrashes, aborts>>

\* A step exits abnormally before finishing (the :DOWN path), or, in a
\* machine call's own code, raises: ToolTask rescues the raise and records
\* an error result, whose commit runs on_interrupt/2 (hub rule 10).
RaisePcs == {"go", "park", "repark_on", "repark_off"}
StepCrash(st) ==
    /\ stepCrashes < MaxStepCrashes
    /\ st.pc # "exited"
    /\ stepCrashes' = stepCrashes + 1
    /\ \/ steps' = StepExit(st)
       \/ IsMachine(st) /\ st.pc \in RaisePcs /\ steps' = StepTo(st, "fin_err")
    /\ UNCHANGED <<dbVars, rowVars, ghostVars, timeVars, inc, hubCrashes, schedCrashes, aborts>>

---------------------------------------------------------------------------

Init ==
    /\ task = [id \in TaskIds |-> IF id \in Routines
                                  THEN [NoTask(id) EXCEPT !.status = "pending", !.phase = "start"]
                                  ELSE NoTask(id)]
    /\ sub = [s \in SubIds |-> NoSub]
    /\ toolResults = [t \in ToolIds |-> 0]
    /\ orphanCalls = 0
    /\ nextGen = 1 /\ nextTool = 1 /\ nextOrd = 1
    /\ row = [t \in ToolIds |-> "none"]
    /\ rcx = [t \in ToolIds |-> FALSE]
    /\ signal = [t \in ToolIds |-> FALSE]
    /\ claims = [t \in ToolIds |-> 0]
    /\ opResult = [t \in ToolIds |-> FALSE]
    /\ execCount = [t \in ToolIds |-> 0]
    /\ untilPassed = [id \in TaskIds |-> FALSE]
    /\ rechecks = [t \in ToolIds |-> 0]
    /\ steps = {}
    /\ inc = 0
    /\ hubCrashes = 0 /\ schedCrashes = 0 /\ stepCrashes = 0 /\ aborts = 0

Next ==
    \/ \E u \in Users : UserSubmit(u)
    \/ UserAbort
    \/ \E id \in TaskIds : SchedStart(id)
    \/ \E id \in TaskIds : SchedWake(id)
    \/ \E id \in TaskIds : SchedKill(id)
    \/ \E id \in TaskIds : SchedAbort(id)
    \/ \E st \in steps : SchedExit(st)
    \/ \E st \in steps : StepAct(st)
    \/ \E st \in steps : StepCrash(st)
    \/ \E t \in ToolIds : OpFinish(t)
    \/ \E id \in TaskIds : Tick(id)
    \/ HubCrash
    \/ SchedCrash

\* What the implementation guarantees: the Scheduler reconciles after every
\* commit touching tasks or signals, after every step result or :DOWN, and
\* on its timer, so each of its actions is weakly fair; step processes keep
\* running; time passes; and an op eventually ends on its machine (the
\* command finishes, or is canceled, once the machine is back; there is no
\* timeout on a running command, so without this a call may wait for
\* good).  The user and faults get no fairness.
SysNext ==
    \/ \E id \in TaskIds : SchedStart(id) \/ SchedWake(id) \/ SchedKill(id) \/ SchedAbort(id)
    \/ \E st \in steps : SchedExit(st) \/ StepAct(st)
    \/ \E id \in TaskIds : Tick(id)
    \/ \E t \in ToolIds : OpFinish(t)

StepOf(id) == \E st \in steps : st.t = id /\ StepAct(st)
ExitOf(id) == \E st \in steps : st.t = id /\ SchedExit(st)

\* Per-action weak fairness, as the implementation provides.
FairnessFine ==
    /\ \A id \in TaskIds :
         /\ WF_vars(SchedStart(id)) /\ WF_vars(SchedWake(id))
         /\ WF_vars(SchedKill(id))  /\ WF_vars(SchedAbort(id))
         /\ WF_vars(ExitOf(id))     /\ WF_vars(StepOf(id))
         /\ WF_vars(Tick(id))
    /\ \A t \in ToolIds : WF_vars(OpFinish(t))

\* One weak-fairness condition on all system actions.  This is weaker than
\* FairnessFine (it allows more behaviors), so a liveness property that holds
\* under it also holds under FairnessFine; it only rules out stopping while
\* the system can still move.  It is much cheaper for TLC.
Fairness == WF_vars(SysNext)

Spec     == Init /\ [][Next]_vars /\ Fairness
SpecFine == Init /\ [][Next]_vars /\ FairnessFine

-----------------------------------------------------------------------------
(* Properties *)

TaskStatuses == {"none", "pending", "running", "waiting"} \cup Terminal
SubStatuses  == {"none", "queued", "placed", "done", "unanswered", "withdrawn"}

TypeOK ==
    /\ \A id \in TaskIds : task[id].status \in TaskStatuses
    /\ \A s \in SubIds : sub[s].status \in SubStatuses
    /\ \A t \in ToolIds : row[t] \in {"none", "open", "finished", "closed"}
    /\ nextGen \in 1..(NGen + 1) /\ nextTool \in 1..(NTools + 1)
    /\ \A st \in steps : st.t \in TaskIds

\* At most one active run (non-background, conversation-owned, unfinished)
AtMostOneActiveRun == Cardinality(ActiveRunsIn(task)) <= 1

\* Every tool task gets exactly one tool_result entry: none while it is
\* live, one once it has finished.
ToolResultIffFinished ==
    \A t \in ToolIds : toolResults[t] = IF task[t].status \in Terminal THEN 1 ELSE 0

\* Every tool call in an assistant entry was given a tool task.
NoOrphanCalls == orphanCalls = 0

\* An aborted task has no live foreground children (stop_aborted is bottom-up).
AbortedHasNoLiveFgChildren ==
    \A id \in TaskIds : task[id].status = "aborted" => FgKids(task, id) = {}

\* A task marked for abort ends "aborted" (on_abort), not "failed" (on_fail).
AbortEndsAborted ==
    \A id \in TaskIds : task[id].abort /\ task[id].status \in Terminal
                         => task[id].status = "aborted"

\* An unsafe tool never executes twice.
UnsafeAtMostOnce == \A t \in ToolIds : execCount[t] <= 1

\* Every placed submission belongs to a live generation that will settle it.
PlacedTracked ==
    \A s \in SubIds : sub[s].status = "placed" =>
        \E g \in GenIds : LiveIn(task, g) /\ s \in task[g].subs

\* A machine call's result is recorded once, and when it is the op's own
\* result, the row it came from was claimed in that commit and closed.
OneResultPerCall ==
    \A t \in ToolIds :
      /\ toolResults[t] <= 1
      /\ opResult[t] => claims[t] = 1 /\ row[t] = "closed" /\ toolResults[t] = 1

\* A finished op's result reaches at most one tool result.
ClaimedOnce == \A t \in ToolIds : claims[t] <= 1

\* Once a call has ended, however it ended, its row is not open without
\* `cancel`: nothing may still start its op (hub rules 7, 9 and 10).
NoOpenRowAfterDone ==
    \A t \in ToolIds : task[t].status \in Terminal => ~(row[t] = "open" /\ ~rcx[t])

\* Stop withdraws only the user's own queued input: a routine's prompt stays.
BackgroundNotWithdrawn == \A r \in Routines : sub[RS(r)].status # "withdrawn"

\* Liveness

PlacedSettles ==
    \A s \in SubIds : sub[s].status = "placed" ~> sub[s].status \in {"done", "unanswered"}

QueuedNotStranded ==
    \A s \in SubIds : sub[s].status = "queued" ~> sub[s].status # "queued"

ToolTasksFinish ==
    \A t \in ToolIds : LiveIn(task, t) ~> task[t].status \in Terminal

NoRunningForever ==
    \A id \in TaskIds : task[id].status = "running" ~> task[id].status # "running"

AbortCompletes ==
    \A id \in TaskIds : (task[id].abort /\ LiveIn(task, id)) ~> ~LiveIn(task, id)

FinishedLeavesNoLiveWork ==
    \A id \in TaskIds : task[id].status \in Terminal ~> FgKids(task, id) = {}

\* Every op row eventually closes, so no result is kept for good (hub
\* rule 8; a finished row whose call ended another way is closed by
\* cancel_tx/2).
RowsClose == \A t \in ToolIds : row[t] # "none" ~> row[t] = "closed"

=============================================================================
