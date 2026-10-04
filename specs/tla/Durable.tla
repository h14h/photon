------------------------------- MODULE Durable -------------------------------
(***************************************************************************)
(* The hub's durable agent harness (the Photon.Durable modules) and the   *)
(* assistant's node-work tools (Photon.Assistant.NodeWork, NodeWatch and   *)
(* Routine), as implemented in apps/hub/lib after the verification fixes   *)
(* (Durable.md lists them).  One conversation.                             *)
(*                                                                         *)
(* Granularity: every Store.commit is one atomic step (the Store runs     *)
(* commits one at a time, each in a DB transaction: Tx.run/1).  Work done  *)
(* outside a commit by a step process (reads, NodeSessions writes, which   *)
(* are Store commits of their own, model calls) is a separate step, so     *)
(* other commits can interleave between them.  The scheduler's per-task    *)
(* commits are separate actions too; its stale snapshot only makes it more *)
(* conservative (see Durable.md).                                          *)
(*                                                                         *)
(* Paths in comments are relative to apps/hub/lib/photon/.  Code is cited  *)
(* by function: the scheduler's rules are Policy (durable/policy.ex), a    *)
(* generation's decisions Turn (durable/turn.ex), a tool call's ToolCall   *)
(* (durable/tool_call.ex), the inbox's Inbox (durable/inbox.ex).           *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS
    Users,          \* user submissions (Photon.Assistant.send), model values
    NTools,         \* tool-call task ids available to the model
    Routines,       \* routine task ids (strings); {} leaves routines out
    MaxRounds,      \* Turn.max_rounds/0 (60, in durable/turn.ex)
    MaxCalls,       \* most tool calls in one model response
    ToolTypes,      \* subset of {"node", "plain"}
    GenPolicy,      \* "all_settled" (Turn.wait_for_tools/2) or "fail_fast" (what-if)
    LLMErrors,      \* model requests may fail ({:error, _} from LLM.stream)
    NodeOffline,    \* the node may be offline when run_on_node runs
    MaxHubCrashes,  \* whole-hub crashes (BEAM dies; DB survives)
    MaxSchedCrashes,\* Scheduler-process-only crashes (supervisor restarts it)
    MaxStepCrashes, \* step processes that raise / exit abnormally
    MaxAborts       \* user Stop presses (Durable.abort/1)

ASSUME MaxRounds >= 1 /\ MaxCalls >= 1 /\ NTools >= 0
ASSUME ToolTypes \subseteq {"node", "plain"} /\ ToolTypes # {}
ASSUME GenPolicy \in {"all_settled", "fail_fast"}

-----------------------------------------------------------------------------
(* Identifiers.  Ids are deterministic so the state space stays small:    *)
(* tool task i is "t<i>", its node input is in_t<i>, its watcher (request *)
(* id "watch:in_t<i>", NodeWork.watcher/3) is "wt<i>", and the watcher's *)
(* report (request id "report:in_t<i>", Report.request_id/1) is "rep_t<i>". *)

ToolAt(i)  == "t" \o ToString(i)
ToolIds    == {ToolAt(i) : i \in 1..NTools}
W(t)       == "w" \o t
WatchIds   == {W(t) : t \in ToolIds}
ToolOf(w)  == CHOOSE t \in ToolIds : W(t) = w
Rep(t)     == "rep_" \o t
RS(r)      == "rs_" \o r
SubIds     == Users \cup {Rep(t) : t \in ToolIds} \cup {RS(r) : r \in Routines}
\* A generation is only created by submit_tx placing a new submission while
\* idle (Durable.submit_tx/4, Inbox.submit_action/3), so there are never more
\* of them than submissions.
NGen       == Cardinality(SubIds)
GenAt(i)   == "g" \o ToString(i)
GenIds     == {GenAt(i) : i \in 1..NGen}
TaskIds    == GenIds \cup ToolIds \cup WatchIds \cup Routines

Kind(id) == CASE id \in GenIds   -> "gen"
              [] id \in ToolIds  -> "tool"
              [] id \in WatchIds -> "watch"
              [] OTHER           -> "routine"

Terminal == {"done", "failed", "aborted"}            \* TaskRecord.terminal_statuses/0
FinPcs   == {"fin_err", "fin_ok", "fin_int"}

VARIABLES
    task,         \* tasks table (task_record.ex); status "none" = not created
    sub,          \* submissions table (submission.ex); status "none" = not created
    signal,       \* signals table: signal[t] <=> "node_input:in_t" recorded
                  \*   (in the same commit that settles the input)
    toolResults,  \* number of "tool_result" entries for tool task t
    answerInTool, \* tool t's result carried the node's answer (NodeWork.resume)
    orphanCalls,  \* tool calls in "assistant" entries that never got a tool task
    nextGen, nextTool, nextOrd,   \* id allocation; nextOrd = inserted_at order
    session,      \* NodeSessions.start ran for t (session + input stored, pushed)
    inputDone,    \* node_inputs row for t settled by NodeSessions.ingest
    execCount,    \* times an unsafe ("plain") tool actually executed
    untilPassed,  \* the deadline ("until") of task id's current wait has passed
    steps,        \* live step processes under Durable.TaskSupervisor
    inc,          \* Scheduler incarnation (bumped by a Scheduler-only crash)
    hubCrashes, schedCrashes, stepCrashes, aborts

dbVars    == <<task, sub, signal, toolResults, answerInTool, orphanCalls,
               nextGen, nextTool, nextOrd>>
extVars   == <<session, inputDone, execCount, untilPassed>>
procVars  == <<steps, inc>>
faultVars == <<hubCrashes, schedCrashes, stepCrashes, aborts>>
vars      == <<dbVars, extVars, procVars, faultVars>>

-----------------------------------------------------------------------------
(* Records *)

\* tok: which start of the task this is (Tx.transition/4 fences on the
\* updated_at the step started with; only a new start or an abort changes
\* a running task).
NoTask(id) ==
    [status |-> "none", phase |-> "none", runs |-> 0, tok |-> 0, abort |-> FALSE,
     owner |-> "none", bg |-> Kind(id) \in {"watch", "routine"},
     wOn |-> {}, wSig |-> "none", wUntil |-> FALSE,
     subs |-> {}, rounds |-> 0, ttype |-> "none"]

\* submit_tx's generation (Durable.submit_tx/4, Inbox.run/2)
NewGen(id, s) == [NoTask(id) EXCEPT !.status = "pending", !.phase = "request",
                                    !.subs = {s}]

\* answered/4 creates one tool task per call (Generation.follow/5, Turn.tool_task/2)
NewTool(id, g, ty) == [NoTask(id) EXCEPT !.status = "pending", !.phase = "run",
                                         !.owner = g, !.ttype = ty]

\* NodeWork.await's watcher (NodeWork.watcher/3): background, no owner
NewWatch(id) == [NoTask(id) EXCEPT !.status = "pending", !.phase = "start"]

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

\* Tx.transition/4 ignores a task that finished or was marked for abort
\* meanwhile, and a step that is no longer the task's current start (its
\* task was reset and started again after a scheduler restart: status not
\* running, or a later start); Runtime.commit then rolls the whole commit
\* back.
Ignored(st) ==
    LET id == st.t IN
    \/ task[id].status \in Terminal \/ task[id].abort
    \/ task[id].status # "running" \/ task[id].tok # st.tok

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
    /\ UNCHANGED <<dbVars, extVars, inc, faultVars>>

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
       /\ UNCHANGED <<signal, toolResults, answerInTool, extVars, inc, faultVars>>
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
            /\ UNCHANGED <<signal, toolResults, answerInTool, orphanCalls, nextGen,
                           nextTool, nextOrd, extVars, inc, faultVars>>

---------------------------------------------------------------------------
(* ToolTask (durable/tool_task.ex, durable/tool_call.ex) with the         *)
(* assistant's tools.                                                       *)
(* "node" = run_on_node / message_node_session (replay :safe, waits).     *)
(* "plain" = a tool with the default replay :unsafe that runs and returns. *)

\* RunOnNode.execute up to NodeSessions.start: Store commits of its own, not
\* the tool's, idempotent by the ids derived from the task id
\* (NodeWork.ids/1).
NodeRun(st) ==
    LET t == st.t IN
    /\ Kind(t) = "tool" /\ task[t].ttype = "node" /\ st.phase = "run" /\ st.pc = "go"
    /\ \E online \in (IF NodeOffline THEN BOOLEAN ELSE {TRUE}) :
         IF online \/ session[t]
         THEN /\ session' = [session EXCEPT ![t] = TRUE]
              /\ steps' = StepTo(st, "watch")
         ELSE /\ steps' = StepTo(st, "fin_err")      \* "Node ... is offline"
              /\ UNCHANGED session
    /\ UNCHANGED <<dbVars, inputDone, execCount, untilPassed, inc, faultVars>>

\* NodeWork.await: Durable.create_task(watcher) is its own commit, deduped by
\* request id "watch:<input>" even if that task already finished
\* (NodeWork.await/4, Tx.create_task/2).
NodeCreateWatcher(st) ==
    LET t == st.t IN
    /\ Kind(t) = "tool" /\ task[t].ttype = "node" /\ st.phase = "run" /\ st.pc = "watch"
    /\ task' = IF task[W(t)].status = "none"
               THEN [task EXCEPT ![W(t)] = NewWatch(W(t))] ELSE task
    /\ steps' = StepTo(st, "wait")
    /\ UNCHANGED <<sub, signal, toolResults, answerInTool, orphanCalls, nextGen,
                   nextTool, nextOrd, extVars, inc, faultVars>>

\* {:wait, %{"signal" => "node_input:<in>", "until" => now + wait}, state}
\* committed by Runtime.transition (NodeWork.await/4, ToolTask.run/3, ToolCall.park/2)
NodeWait(st) ==
    LET t == st.t IN
    /\ st.pc = "wait"
    /\ IF Ignored(st) THEN IgnoredCommit(st)
       ELSE /\ task' = WaitIn(task, t, {}, t, TRUE, "resume", {}, 0)
            /\ untilPassed' = [untilPassed EXCEPT ![t] = FALSE]
            /\ steps' = StepDone(st)
            /\ UNCHANGED <<sub, signal, toolResults, answerInTool, orphanCalls,
                           nextGen, nextTool, nextOrd, session, inputDone,
                           execCount, inc, faultVars>>

\* NodeWork.resume returns {:commit, fun}: one Runtime.commit reads the
\* signal, and if the node has answered and no report was posted (the
\* report submission doesn't exist), stops the watcher and records the
\* answer; otherwise the result says the work is still running, or that the
\* report is in the conversation.  An aborted call's commit is ignored
\* whole, so the watcher is left alone.
NodeResume(st) ==
    LET t == st.t
        answered == signal[t]
        reported == sub[Rep(t)].status # "none"
    IN
    /\ Kind(t) = "tool" /\ task[t].ttype = "node" /\ st.phase = "resume" /\ st.pc = "go"
    /\ IF Ignored(st) THEN IgnoredCommit(st)
       ELSE /\ toolResults' = [toolResults EXCEPT ![t] = @ + 1]
            /\ answerInTool' = [answerInTool EXCEPT ![t] = answered /\ ~reported]
            /\ task' = FinishIn(IF answered /\ ~reported /\ task[W(t)].status # "none"
                                THEN ReqAbort(task, W(t)) ELSE task, t, "done")
            /\ steps' = StepDone(st)
            /\ UNCHANGED <<sub, signal, orphanCalls, nextGen, nextTool, nextOrd,
                           extVars, inc, faultVars>>

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
    /\ UNCHANGED <<dbVars, session, inputDone, untilPassed, inc, faultVars>>

\* ToolTask.finish: the tool_result entry and {:done} in one Runtime.commit.
ToolFinish(st) ==
    LET t == st.t IN
    /\ Kind(t) = "tool" /\ st.pc \in FinPcs
    /\ IF Ignored(st) THEN IgnoredCommit(st)
       ELSE /\ toolResults' = [toolResults EXCEPT ![t] = @ + 1]
            /\ answerInTool' = [answerInTool EXCEPT ![t] = FALSE]
            /\ task' = FinishIn(task, t, "done")
            /\ steps' = StepDone(st)
            /\ UNCHANGED <<sub, signal, orphanCalls, nextGen, nextTool, nextOrd,
                           extVars, inc, faultVars>>

---------------------------------------------------------------------------
(* NodeWatch (assistant/node_watch.ex) and Routine (assistant/routine.ex) *)

\* step("start"): wait on the signal (NodeWatch.wait_for_signal/1)
WatchStart(st) ==
    LET w == st.t IN
    /\ Kind(w) = "watch" /\ st.phase = "start" /\ st.pc = "go"
    /\ IF Ignored(st) THEN IgnoredCommit(st)
       ELSE /\ task' = WaitIn(task, w, {}, ToolOf(w), FALSE, "report", {}, 0)
            /\ steps' = StepDone(st)
            /\ UNCHANGED <<sub, signal, toolResults, answerInTool, orphanCalls,
                           nextGen, nextTool, nextOrd, extVars, inc, faultVars>>

\* step("report"): while the call that started the work is still live (and
\* not marked for abort), wait for it to finish, since it reports a quick
\* answer itself; otherwise submit_tx(report, request_id "report:<in>") and
\* {:done} in one Runtime.commit.
WatchReport(st) ==
    LET w == st.t
        t == ToolOf(w)
        s == Rep(t)
    IN
    /\ Kind(w) = "watch" /\ st.phase = "report" /\ st.pc = "go"
    /\ IF Ignored(st) THEN IgnoredCommit(st)
       ELSE IF LiveIn(task, t) /\ ~task[t].abort
       THEN /\ task' = WaitIn(task, w, {t}, "none", FALSE, "report", {}, 0)
            /\ steps' = StepDone(st)
            /\ UNCHANGED <<sub, signal, toolResults, answerInTool, orphanCalls,
                           nextGen, nextTool, nextOrd, extVars, inc, faultVars>>
       ELSE /\ task' = FinishIn(SubmitTk(task, sub, s), w, "done")
            /\ sub' = SubmitSb(task, sub, s, "follow_up")
            /\ nextGen' = SubmitGen(task, sub, s)
            /\ nextOrd' = SubmitOrd(sub, s)
            /\ steps' = StepDone(st)
            /\ UNCHANGED <<signal, toolResults, answerInTool, orphanCalls, nextTool,
                           extVars, inc, faultVars>>

\* step("start"): sleep until first_at (Routine.first_wait/1)
RoutineStart(st) ==
    LET r == st.t IN
    /\ Kind(r) = "routine" /\ st.phase = "start" /\ st.pc = "go"
    /\ IF Ignored(st) THEN IgnoredCommit(st)
       ELSE /\ task' = WaitIn(task, r, {}, "none", TRUE, "fire", {}, 0)
            /\ untilPassed' = [untilPassed EXCEPT ![r] = FALSE]
            /\ steps' = StepDone(st)
            /\ UNCHANGED <<sub, signal, toolResults, answerInTool, orphanCalls,
                           nextGen, nextTool, nextOrd, session, inputDone,
                           execCount, inc, faultVars>>

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
            /\ UNCHANGED <<signal, toolResults, answerInTool, orphanCalls, nextTool,
                           extVars, inc, faultVars>>

StepAct(st) ==
    \/ GenRequest(st) \/ GenAfterTools(st)
    \/ NodeRun(st) \/ NodeCreateWatcher(st) \/ NodeWait(st) \/ NodeResume(st)
    \/ PlainRun(st) \/ ToolFinish(st)
    \/ WatchStart(st) \/ WatchReport(st) \/ RoutineStart(st) \/ RoutineFire(st)

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
                             subs |-> task[id].subs, rounds |-> task[id].rounds]}
    /\ UNCHANGED <<sub, signal, toolResults, answerInTool, orphanCalls, nextGen,
                   nextTool, nextOrd, extVars, inc, faultVars>>

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
    /\ UNCHANGED <<sub, signal, toolResults, answerInTool, orphanCalls, nextGen,
                   nextTool, nextOrd, extVars, procVars, faultVars>>

\* stop_aborted/2, first half: terminate_child for a marked task whose step
\* this Scheduler is running (Policy.steps_to_kill/2).  A step that already
\* returned (result not yet handled) is not found, so nothing happens to it.
SchedKill(id) ==
    /\ task[id].abort /\ LiveIn(task, id)
    /\ \E st \in CurSteps(id) : st.pc # "exited" /\ steps' = steps \ {st}
    /\ UNCHANGED <<dbVars, extVars, inc, faultVars>>

\* on_abort/on_fail hooks run in the commit that ends the task that way.
\* Generation settles its submissions; ToolTask records the result, and for
\* a node tool whose session was started its on_interrupt makes sure a
\* watcher exists (NodeWork.ensure_watcher, idempotent by request id).
OnAbortSb(id, sb) ==
    IF Kind(id) = "gen" THEN Settle(sb, task[id].subs, "unanswered") ELSE sb
OnAbortTr(id) ==
    IF Kind(id) = "tool" THEN [toolResults EXCEPT ![id] = @ + 1] ELSE toolResults
OnAbortTk(id, tk) ==
    IF Kind(id) = "tool" /\ tk[id].ttype = "node" /\ session[id] /\ tk[W(id)].status = "none"
    THEN [tk EXCEPT ![W(id)] = NewWatch(W(id))]
    ELSE tk

\* stop_aborted/2, second half: a marked task with no live foreground work is
\* aborted, bottom-up (Policy.ready_to_abort/1, Scheduler.abort_tx/2).  Its kills come first.
SchedAbort(id) ==
    /\ task[id].abort /\ LiveIn(task, id)
    /\ FgKids(task, id) = {}
    /\ ~\E st \in CurSteps(id) : st.pc # "exited"
    /\ LET r == HandOff(id, [OnAbortTk(id, task) EXCEPT ![id].status = "aborted", ![id].wOn = {},
                                                  ![id].wSig = "none", ![id].wUntil = FALSE],
                        OnAbortSb(id, sub))
       IN  /\ task' = r[1] /\ sub' = r[2] /\ nextGen' = r[3]
    /\ toolResults' = OnAbortTr(id)
    /\ UNCHANGED <<signal, answerInTool, orphanCalls, nextTool, nextOrd,
                   extVars, procVars, faultVars>>

\* Scheduler.fail/2 with the on_fail hooks.  NodeWatch.on_fail asks for its
\* phase to run again (:retry; it gives up only after three runs, which the
\* bounded crashes here never reach).
FailCommit(id) ==
    IF Kind(id) = "watch"
    THEN /\ task' = [task EXCEPT ![id].status = "pending"]
         /\ UNCHANGED <<sub, nextGen, toolResults>>
    ELSE /\ LET r == HandOff(id, FinishIn(OnAbortTk(id, task), id, "failed"), OnAbortSb(id, sub))
            IN  /\ task' = r[1] /\ sub' = r[2] /\ nextGen' = r[3]
         /\ toolResults' = OnAbortTr(id)

\* A step's result or :DOWN: if the task is still "running" the step ended
\* without a transition (or crashed), so it fails, unless it is marked for
\* abort, which stop_aborted then finishes as aborted.  A step killed by
\* stop_aborted never gets here (it is in state.killed).
SchedExit(st) ==
    /\ st \in steps /\ st.inc = inc /\ st.pc = "exited"
    /\ steps' = steps \ {st}
    /\ IF task[st.t].status = "running" /\ ~task[st.t].abort
       THEN /\ FailCommit(st.t)
            /\ UNCHANGED <<signal, answerInTool, orphanCalls, nextTool, nextOrd>>
       ELSE UNCHANGED dbVars
    /\ UNCHANGED <<extVars, inc, faultVars>>

---------------------------------------------------------------------------
(* The user, the node, and time *)

\* Photon.Assistant.send -> Durable.submit (Assistant.send/2, Durable.submit/3)
UserSubmit(u) ==
    /\ sub[u].status = "none"
    /\ \E mode \in {"follow_up", "steer"} :
         /\ task' = SubmitTk(task, sub, u)
         /\ sub' = SubmitSb(task, sub, u, mode)
         /\ nextGen' = SubmitGen(task, sub, u)
         /\ nextOrd' = SubmitOrd(sub, u)
    /\ UNCHANGED <<signal, toolResults, answerInTool, orphanCalls, nextTool,
                   extVars, procVars, faultVars>>

\* Assistant.stop -> Durable.abort/2: withdraw the user's queued input (node
\* reports and routine prompts stay), mark the run.
UserAbort ==
    /\ aborts < MaxAborts
    /\ aborts' = aborts + 1
    /\ sub' = [x \in SubIds |-> IF sub[x].status = "queued" /\ x \in Users
                                THEN [sub[x] EXCEPT !.status = "withdrawn"] ELSE sub[x]]
    /\ task' = IF IdleIn(task) THEN task
               ELSE ReqAbort(task, CHOOSE r \in ActiveRunsIn(task) : TRUE)
    /\ UNCHANGED <<signal, toolResults, answerInTool, orphanCalls, nextGen, nextTool,
                   nextOrd, extVars, procVars, hubCrashes, schedCrashes, stepCrashes>>

\* The node's session goes idle (or rejects the input): NodeSessions.ingest
\* settles the input and records Durable's signal in one Store commit
\* (reject_input too).  Replays after a reconnect are :duplicate.
NodeSettle(t) ==
    /\ session[t] /\ ~inputDone[t]
    /\ inputDone' = [inputDone EXCEPT ![t] = TRUE]
    /\ signal' = [signal EXCEPT ![t] = TRUE]
    /\ UNCHANGED <<task, sub, toolResults, answerInTool, orphanCalls, nextGen,
                   nextTool, nextOrd, session, execCount, untilPassed, procVars, faultVars>>

\* A waiting task's deadline passes; the Scheduler's timer (arm_timer/1,
\* Policy.timer_delay/2) then reconciles.
Tick(id) ==
    /\ task[id].status = "waiting" /\ task[id].wUntil /\ ~untilPassed[id]
    /\ untilPassed' = [untilPassed EXCEPT ![id] = TRUE]
    /\ UNCHANGED <<dbVars, session, inputDone, execCount, procVars, faultVars>>

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
    /\ UNCHANGED <<sub, signal, toolResults, answerInTool, orphanCalls, nextGen,
                   nextTool, nextOrd, session, inputDone, execCount, untilPassed,
                   inc, schedCrashes, stepCrashes, aborts>>

\* Only the Scheduler process dies; its supervisor (Durable.Supervisor,
\* one_for_one) restarts it.  Steps run under the separate Durable.TaskSupervisor via
\* async_nolink, so they keep running; init resets every running task to
\* pending, and the old steps' commits are fenced out (Ignored).
SchedCrash ==
    /\ schedCrashes < MaxSchedCrashes
    /\ schedCrashes' = schedCrashes + 1
    /\ inc' = inc + 1
    /\ steps' = {st \in steps : st.pc # "exited"}
    /\ task' = RunningToPending
    /\ UNCHANGED <<sub, signal, toolResults, answerInTool, orphanCalls, nextGen,
                   nextTool, nextOrd, extVars, hubCrashes, stepCrashes, aborts>>

\* A step raises or exits before finishing (the :DOWN path).
StepCrash(st) ==
    /\ stepCrashes < MaxStepCrashes
    /\ st.pc # "exited"
    /\ stepCrashes' = stepCrashes + 1
    /\ steps' = StepExit(st)
    /\ UNCHANGED <<dbVars, extVars, inc, hubCrashes, schedCrashes, aborts>>

---------------------------------------------------------------------------

Init ==
    /\ task = [id \in TaskIds |-> IF id \in Routines
                                  THEN [NoTask(id) EXCEPT !.status = "pending", !.phase = "start"]
                                  ELSE NoTask(id)]
    /\ sub = [s \in SubIds |-> NoSub]
    /\ signal = [t \in ToolIds |-> FALSE]
    /\ toolResults = [t \in ToolIds |-> 0]
    /\ answerInTool = [t \in ToolIds |-> FALSE]
    /\ orphanCalls = 0
    /\ nextGen = 1 /\ nextTool = 1 /\ nextOrd = 1
    /\ session = [t \in ToolIds |-> FALSE]
    /\ inputDone = [t \in ToolIds |-> FALSE]
    /\ execCount = [t \in ToolIds |-> 0]
    /\ untilPassed = [id \in TaskIds |-> FALSE]
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
    \/ \E st \in steps : GenRequest(st)
    \/ \E st \in steps : GenAfterTools(st)
    \/ \E st \in steps : NodeRun(st)
    \/ \E st \in steps : NodeCreateWatcher(st)
    \/ \E st \in steps : NodeWait(st)
    \/ \E st \in steps : NodeResume(st)
    \/ \E st \in steps : PlainRun(st)
    \/ \E st \in steps : ToolFinish(st)
    \/ \E st \in steps : WatchStart(st)
    \/ \E st \in steps : WatchReport(st)
    \/ \E st \in steps : RoutineStart(st)
    \/ \E st \in steps : RoutineFire(st)
    \/ \E st \in steps : StepCrash(st)
    \/ \E t \in ToolIds : NodeSettle(t)
    \/ \E id \in TaskIds : Tick(id)
    \/ HubCrash
    \/ SchedCrash

\* What the implementation guarantees: the Scheduler reconciles after every
\* commit touching tasks or signals, after every step result or :DOWN, and
\* on its timer, so each of its actions is weakly fair; step processes keep
\* running; time passes.  The user, the node and faults get no fairness.
SysNext ==
    \/ \E id \in TaskIds : SchedStart(id) \/ SchedWake(id) \/ SchedKill(id) \/ SchedAbort(id)
    \/ \E st \in steps : SchedExit(st) \/ StepAct(st)
    \/ \E id \in TaskIds : Tick(id)

StepOf(id) == \E st \in steps : st.t = id /\ StepAct(st)
ExitOf(id) == \E st \in steps : st.t = id /\ SchedExit(st)

\* Per-action weak fairness, as the implementation provides.
FairnessFine ==
    /\ \A id \in TaskIds :
         /\ WF_vars(SchedStart(id)) /\ WF_vars(SchedWake(id))
         /\ WF_vars(SchedKill(id))  /\ WF_vars(SchedAbort(id))
         /\ WF_vars(ExitOf(id))     /\ WF_vars(StepOf(id))
         /\ WF_vars(Tick(id))

\* One weak-fairness condition on all system actions.  This is weaker than
\* FairnessFine (it allows more behaviors), so a liveness property that holds
\* under it also holds under FairnessFine; it only rules out stopping while
\* the system can still move.  Every counterexample reported in Durable.md
\* ends in such a stop with no system action enabled, so it is a
\* counterexample under FairnessFine too.  It is much cheaper for TLC.
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

\* The user receives a node input's answer as the tool result (early) or as
\* the watcher's report entry (placed in the transcript).
ReportSeen(t) == sub[Rep(t)].status \in {"placed", "done", "unanswered"}
Delivered(t)  == answerInTool[t] \/ ReportSeen(t)

\* ... never both
NoDoubleDelivery == \A t \in ToolIds : ~(answerInTool[t] /\ ReportSeen(t))

\* A node report is never withdrawn before the user sees it.
ReportsNotWithdrawn == \A t \in ToolIds : sub[Rep(t)].status # "withdrawn"

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

\* ... and never zero times, once the node has finished the input
DeliveredOnceAnswered == \A t \in ToolIds : inputDone[t] ~> Delivered(t)

\* Weaker forms, to separate the ways a Stop loses the answer
ReportWithdrawn(t) == sub[Rep(t)].status = "withdrawn"
NoWatcher(t)       == task[W(t)].status = "none"
DeliveredUnlessWithdrawn ==
    \A t \in ToolIds : inputDone[t] ~> (Delivered(t) \/ ReportWithdrawn(t))
DeliveredUnlessWithdrawnOrUnwatched ==
    \A t \in ToolIds : inputDone[t] ~> (Delivered(t) \/ ReportWithdrawn(t) \/ NoWatcher(t))
\* The report was never even submitted
ReportSubmitted(t) == sub[Rep(t)].status # "none"
DeliveredOrReported ==
    \A t \in ToolIds : inputDone[t] ~> (Delivered(t) \/ ReportSubmitted(t))
\* The watcher existed and the report was never even submitted
ReportedOrUnwatched ==
    \A t \in ToolIds : inputDone[t] ~> (Delivered(t) \/ sub[Rep(t)].status # "none" \/ NoWatcher(t))

=============================================================================
