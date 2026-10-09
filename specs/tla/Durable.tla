------------------------------- MODULE Durable -------------------------------
(***************************************************************************)
(* The hub's durable agent harness (the Photon.Durable modules), with a    *)
(* machine tool (Photon.MachineTools.Call: shell and view_image) and the   *)
(* routine task behind a schedule (Photon.Schedules.Routine), as built in  *)
(* apps/hub/lib after build step 1, with step 3's schedules: a routine     *)
(* that repeats, and the owner's edits and deletes that replace or retire  *)
(* it (Photon.Schedules.update/3, delete/1), and step 4's ask_blip call    *)
(* (Photon.Threads.Tools.AskBlip over Photon.Questions) with Blip's side   *)
(* of it reduced to the question's carrier, and the settle hook            *)
(* (Durable.settled/3, Profile.on_settled/3).  Durable.md lists the        *)
(* findings and how they were fixed.  One conversation.                    *)
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
    Routines,       \* the routine task carrying the schedule at the start (at
                    \*   most one; {} leaves schedules out)
    Spares,         \* routine task ids an edit can create; {} leaves edits out
    MaxFires,       \* firings of a routine before it finishes (1: a one-off)
    MaxEdits,       \* owner edits of the schedule (Schedules.update/3)
    MaxDeletes,     \* owner deletes of the schedule (Schedules.delete/1)
    Target,         \* "conv": a firing posts into the modeled conversation
                    \*   (Blip's, or a thread a schedule wakes); "thread": it
                    \*   starts a new thread, another conversation (a count)
    BugEditKeepsOld,     \* bug switch: an edit doesn't mark the old routine
    BugFireIgnoresAbort, \* bug switch: the fire commit ignores the abort mark
    BugAskUnfenced,      \* bug switch: Questions.ask/1 inserts whatever the task's state
    BugAnswerAnyStatus,  \* bug switch: the owner's answer skips Rules.step/2's status check
    MaxRounds,      \* Turn.max_rounds/0 (60, in durable/turn.ex)
    MaxCalls,       \* most tool calls in one model response
    ToolTypes,      \* subset of {"machine", "plain", "ask"}
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
ASSUME ToolTypes \subseteq {"machine", "plain", "ask"} /\ ToolTypes # {}
ASSUME GenPolicy \in {"all_settled", "fail_fast"}
ASSUME Cardinality(Routines) <= 1 /\ Routines \cap Spares = {}
ASSUME MaxFires >= 1 /\ MaxEdits >= 0 /\ MaxDeletes >= 0
ASSUME (Spares # {} \/ MaxEdits > 0 \/ MaxDeletes > 0) => Routines # {}
ASSUME Target \in {"conv", "thread"}
ASSUME BugEditKeepsOld \in BOOLEAN /\ BugFireIgnoresAbort \in BOOLEAN
ASSUME BugAskUnfenced \in BOOLEAN /\ BugAnswerAnyStatus \in BOOLEAN

-----------------------------------------------------------------------------
(* Identifiers.  Ids are deterministic so the state space stays small:    *)
(* tool task i is "t<i>", and a machine call's op row and signal are keyed *)
(* by its task (the op ID is derived from the task ID, Wait.op_id/1), and  *)
(* so are an ask call's question row and its signal "question:<id>" (one   *)
(* question per call, found by task_id).  A                                *)
(* routine r's k-th firing posts the submission "rs_<r>_<k>" (its request *)
(* ID is "schedule:<id>:<task id>:<runs>", runs = k - 1).                 *)

ToolAt(i)  == "t" \o ToString(i)
ToolIds    == {ToolAt(i) : i \in 1..NTools}
RoutineIds == Routines \cup Spares
RS(r, k)   == "rs_" \o r \o "_" \o ToString(k)
\* Only a firing into the modeled conversation makes a submission here; a
\* new-thread firing's input is in the thread it starts.
RSIds      == IF Target = "conv" THEN {RS(r, k) : r \in RoutineIds, k \in 1..MaxFires} ELSE {}
SubIds     == Users \cup RSIds
\* A generation is only created by submit_tx placing a new submission while
\* idle (Durable.submit_tx/4, Inbox.submit_action/3), so there are never more
\* of them than submissions.
NGen       == Cardinality(SubIds)
GenAt(i)   == "g" \o ToString(i)
GenIds     == {GenAt(i) : i \in 1..NGen}
TaskIds    == GenIds \cup ToolIds \cup RoutineIds

Kind(id) == CASE id \in GenIds   -> "gen"
              [] id \in ToolIds  -> "tool"
              [] OTHER           -> "routine"

Terminal == {"done", "failed", "aborted"}            \* TaskRecord.terminal_statuses/0
FinPcs   == {"fin_err", "fin_ok", "fin_int", "fin_ans"}

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
    hubCrashes, schedCrashes, stepCrashes, aborts,
    carrier,      \* the routine the schedule's row names (task_id), "none" once
                  \*   the row is deleted
    fires,        \* firing commits per routine (with Target "thread", the
                  \*   threads it started)
    retired,      \* an edit or delete replaced the routine
    lateFire,     \* ghost: a fire step's commit landed after its routine was retired
    dupFire,      \* ghost: two firing commits for one routine and checkpoint
    edits, deletes,
    q,            \* ask call t's question row (questions/question.ex): "none",
                  \*   "asked", "with_owner", "answered", "withdrawn"
    qsub,         \* its carrier, the submission in Blip's conversation that carries
                  \*   the question signal: "none", "queued", "placed", "settled",
                  \*   "withdrawn" (Signals.unpost_tx/2)
    asks,         \* ghost: question rows inserted for t
    answers,      \* ghost: answers accepted for t's question
    lateAnswer,   \* ghost: an answer was accepted for a withdrawn question
    qResult,      \* ghost: t's tool result is its question's answer (an ok result)
    hooked,       \* ghost: the settle keys on_settled/3 ran for (a settled
                  \*   submission, or "<gen>:end" for a settle that closed none)
    dupHook       \* ghost: on_settled/3 ran twice for one key

dbVars    == <<task, sub, toolResults, orphanCalls, nextGen, nextTool, nextOrd>>
rowVars   == <<row, rcx, signal>>
ghostVars == <<claims, opResult, execCount>>
timeVars  == <<untilPassed, rechecks>>
procVars  == <<steps, inc>>
faultVars == <<hubCrashes, schedCrashes, stepCrashes, aborts>>
schedVars == <<carrier, fires, retired, lateFire, dupFire, edits, deletes>>
qVars     == <<q, qsub>>
qGhosts   == <<asks, answers, lateAnswer, qResult>>
hookVars  == <<hooked, dupHook>>
askVars   == <<qVars, qGhosts, hookVars>>
vars      == <<dbVars, rowVars, ghostVars, timeVars, procVars, faultVars, schedVars, askVars>>

-----------------------------------------------------------------------------
(* Records *)

\* tok: which start of the task this is (Tx.transition/4 fences on the
\* updated_at the step started with; only a new start or an abort changes
\* a running task).  off: a machine call's "offline_since" is set (its
\* parked state, Call.park/4 and Wait.next/4).  fired: a routine's
\* checkpoint "runs", how often it has fired.
NoTask(id) ==
    [status |-> "none", phase |-> "none", runs |-> 0, tok |-> 0, abort |-> FALSE,
     owner |-> "none", bg |-> Kind(id) = "routine",
     wOn |-> {}, wSig |-> "none", wUntil |-> FALSE,
     subs |-> {}, rounds |-> 0, ttype |-> "none", off |-> FALSE, fired |-> 0]

\* A routine as Schedules creates it, with the row or on an edit: pending,
\* phase "start", background.
NewRoutine(id) == [NoTask(id) EXCEPT !.status = "pending", !.phase = "start"]

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
Oldest(sb, qd) == CHOOSE x \in qd : \A y \in qd : sb[x].ord <= sb[y].ord
Place(sb, ss) == [x \in SubIds |-> IF x \in ss THEN [sb[x] EXCEPT !.status = "placed"]
                                   ELSE sb[x]]
\* Generation.settle/4 (Turn.settlement/2): only "placed" ones
Settle(sb, ss, st) ==
    [x \in SubIds |-> IF x \in ss /\ sb[x].status = "placed"
                      THEN [sb[x] EXCEPT !.status = st] ELSE sb[x]]
\* Generation.continue_with_inbox/3 (Inbox.next_input/1): all queued steers, else the
\* oldest queued input
NextInput(sb) ==
    LET qd == Queued(sb)
        steers == {x \in qd : sb[x].mode = "steer"}
    IN  IF steers # {} THEN steers ELSE IF qd = {} THEN {} ELSE {Oldest(sb, qd)}

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

\* The settle hook (Durable.settled/3 -> the profile's on_settled/3), run by
\* Generation right after each settle/4, inside the same commit, with the
\* submissions that settle closed (the placed ones among ss, as sb has them
\* before the settle). Its signal key is "settle:<submission id>" for the
\* first of them, or "settle:<generation id>:end" when it closed none
\* (Signals), so a key seen twice is a hook run twice for one settle, or a
\* signal posted twice.
HookKeys(g, ss, sb) ==
    LET closed == {x \in ss : sb[x].status = "placed"}
    IN  IF closed = {} THEN {g \o ":end"} ELSE closed
RunHook(g, ss, sb) ==
    /\ hooked' = hooked \cup HookKeys(g, ss, sb)
    /\ dupHook' = (dupHook \/ HookKeys(g, ss, sb) \cap hooked # {})

\* Questions.withdraw_tx/2, an ask call's on_interrupt/2, in the commit that
\* ends the call another way: an open question ("asked" or "with_owner")
\* becomes "withdrawn", and a carrier still queued is taken back
\* (Signals.unpost_tx/2).  A no-op for other tools (no question).
Withdraw(t) ==
    /\ q' = [q EXCEPT ![t] = IF @ \in {"asked", "with_owner"} THEN "withdrawn" ELSE @]
    /\ qsub' = [qsub EXCEPT ![t] = IF @ = "queued" THEN "withdrawn" ELSE @]

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
    /\ UNCHANGED <<dbVars, rowVars, ghostVars, timeVars, inc, faultVars, schedVars, askVars>>

---------------------------------------------------------------------------
(* Generation (durable/generation.ex, decisions in durable/turn.ex) *)

\* step("request"): one model request (no commit), then one Runtime.commit of
\* answered/4 or of the failure (Generation.commit_result/4).  The model's answer is
\* chosen at commit time; nothing between the call and the commit depends on it.
\* Every branch that settles runs the settle hook in the same commit.
GenRequest(st) ==
    LET g == st.t IN
    /\ Kind(g) = "gen" /\ st.pc = "go" /\ st.phase = "request"
    /\ IF Ignored(st) THEN IgnoredCommit(st)
       ELSE
       /\ steps' = StepDone(st)
       /\ UNCHANGED <<toolResults, rowVars, ghostVars, timeVars, inc, faultVars, schedVars,
                      qVars, qGhosts>>
       /\ \/ \* answer without tool calls: settle "done", continue with the
             \* inbox (Generation.follow/5, continue_with_inbox/3)
             LET sb1 == Settle(sub, st.subs, "done")
                 nxt == NextInput(sb1)
             IN  /\ sub' = Place(sb1, nxt)
                 /\ task' = IF nxt = {} THEN FinishIn(task, g, "done")
                            ELSE NextIn(task, g, "request", nxt, 0)
                 /\ RunHook(g, st.subs, sub)
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
             /\ RunHook(g, st.subs, sub)
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
                     /\ UNCHANGED <<sub, orphanCalls, nextGen, nextOrd, hookVars>>
                ELSE \* too many rounds: the assistant entry with the calls is
                     \* stored, each call gets a "Not run" tool_result in the
                     \* same commit, and the run goes on with the inbox or
                     \* fails like a failed request
                     /\ LET sb1 == Settle(sub, st.subs, "unanswered")
                            nxt == NextInput(sb1)
                        IN  /\ sub' = Place(sb1, nxt)
                            /\ task' = IF nxt = {} THEN FinishIn(task, g, "failed")
                                       ELSE NextIn(task, g, "request", nxt, 0)
                     /\ RunHook(g, st.subs, sub)
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
                           rowVars, ghostVars, timeVars, inc, faultVars, schedVars, askVars>>

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
    /\ UNCHANGED <<dbVars, rcx, signal, ghostVars, timeVars, inc, faultVars, schedVars, askVars>>

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
                           rowVars, ghostVars, rechecks, inc, faultVars, schedVars, askVars>>

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
    /\ UNCHANGED <<dbVars, rowVars, ghostVars, timeVars, inc, faultVars, schedVars, askVars>>

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
                           rowVars, ghostVars, inc, faultVars, schedVars, askVars>>

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
                           execCount, timeVars, inc, faultVars, schedVars, askVars>>

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
    /\ UNCHANGED <<dbVars, rowVars, claims, opResult, timeVars, inc, faultVars, schedVars, askVars>>

\* ToolTask.finish: the tool_result entry and {:done} in one Runtime.commit.
\* A machine call's error result cancels its op in the same commit
\* (Call.fail/2 -> cancel_tx/2, hub rule 10), and so does the commit that
\* records a raise ToolTask rescued (ToolTask.raised/3 runs on_interrupt/2).
\* For a plain tool there is no row, so CancelRow changes nothing.  An ask
\* call's answer ("fin_ans", AskBlip.resume/2 on an answered question)
\* is its ok result; its error results (stopped before the ask, a
\* withdrawn or missing question, a rescued raise) run on_interrupt/2's
\* withdraw, which only a raise finds anything to do for.  The
\* on_tool_result/4 hook runs in this commit too; toolResults already
\* counts it.
ToolFinish(st) ==
    LET t == st.t IN
    /\ Kind(t) = "tool" /\ st.pc \in FinPcs
    /\ IF Ignored(st) THEN IgnoredCommit(st)
       ELSE /\ toolResults' = [toolResults EXCEPT ![t] = @ + 1]
            /\ task' = FinishIn(task, t, "done")
            /\ steps' = StepDone(st)
            /\ CancelRow(t)
            /\ IF st.pc = "fin_ans"
               THEN /\ qResult' = [qResult EXCEPT ![t] = TRUE]
                    /\ UNCHANGED qVars
               ELSE /\ Withdraw(t)
                    /\ UNCHANGED qResult
            /\ UNCHANGED <<sub, orphanCalls, nextGen, nextTool, nextOrd, signal,
                           ghostVars, timeVars, inc, faultVars, schedVars,
                           asks, answers, lateAnswer, hookVars>>

---------------------------------------------------------------------------
(* ask_blip (threads/tools/ask_blip.ex, AskBlip) over Photon.Questions     *)
(* (questions.ex, rules in questions/rules.ex, Rules) and Photon.Signals   *)
(* (signals.ex).  replay :safe.  The call's question and its signal are    *)
(* keyed by the task.                                                      *)

IsAsk(st) == Kind(st.t) = "tool" /\ task[st.t].ttype = "ask"

\* AskBlip.execute/2 up to Questions.ask/1, a Store commit of its own, not
\* the step's, so the start token doesn't fence it.  A question with this
\* task_id is returned as it is (a rerun after a restart parks on it
\* again).  Otherwise the question is inserted ("asked") and its signal
\* posted into Blip's conversation (Signals.post_tx/2; the carrier is
\* queued, and BlipPlace stands for a Blip run placing it, at once when
\* Blip is idle) only while the task is unfinished and not marked for
\* abort (Rules.askable?/1, hub rule 9's shape); else {:error, :stopped}
\* and the call's error result.  BugAskUnfenced drops that check.
QAsk(st) ==
    LET t == st.t IN
    /\ IsAsk(st) /\ st.phase = "run" /\ st.pc = "go"
    /\ CASE q[t] # "none" ->
              /\ steps' = StepTo(st, "park")
              /\ UNCHANGED <<qVars, asks>>
         [] (LiveIn(task, t) /\ ~task[t].abort) \/ BugAskUnfenced ->
              /\ q' = [q EXCEPT ![t] = "asked"]
              /\ qsub' = [qsub EXCEPT ![t] = "queued"]
              /\ asks' = [asks EXCEPT ![t] = @ + 1]
              /\ steps' = StepTo(st, "park")
         [] OTHER ->
              /\ steps' = StepTo(st, "fin_err")
              /\ UNCHANGED <<qVars, asks>>
    /\ UNCHANGED <<dbVars, rowVars, ghostVars, timeVars, inc, faultVars, schedVars,
                   answers, lateAnswer, qResult, hookVars>>

\* {:wait, %{"signal" => "question:<id>", "until" => now + check_ms}, ...}
\* through Runtime.transition (ToolCall.park/2): the first park, and
\* again while Blip still has the question and its carrier is queued or
\* placed ("q_repark", a recheck).
QPark(st) ==
    LET t == st.t IN
    /\ IsAsk(st) /\ st.pc \in {"park", "q_repark"}
    /\ IF Ignored(st) THEN IgnoredCommit(st)
       ELSE /\ task' = Park(task, t, FALSE)
            /\ untilPassed' = [untilPassed EXCEPT ![t] = FALSE]
            /\ rechecks' = IF st.pc = "q_repark" THEN [rechecks EXCEPT ![t] = @ + 1]
                            ELSE rechecks
            /\ steps' = StepDone(st)
            /\ UNCHANGED <<sub, toolResults, orphanCalls, nextGen, nextTool, nextOrd,
                           rowVars, ghostVars, inc, faultVars, schedVars, askVars>>

\* {:wait, %{"signal" => "question:<id>"}, ...}: the signal alone, once the
\* question is with the owner; only an answer or a stop moves it now.
QParkSig(st) ==
    LET t == st.t IN
    /\ IsAsk(st) /\ st.pc = "park_sig"
    /\ IF Ignored(st) THEN IgnoredCommit(st)
       ELSE /\ task' = WaitIn(task, t, {}, t, FALSE, "resume", {}, 0)
            /\ untilPassed' = [untilPassed EXCEPT ![t] = FALSE]
            /\ steps' = StepDone(st)
            /\ UNCHANGED <<sub, toolResults, orphanCalls, nextGen, nextTool, nextOrd,
                           rowVars, ghostVars, rechecks, inc, faultVars, schedVars, askVars>>

\* AskBlip.resume/2 reads the question (Questions.get/1) and its carrier's
\* status, outside any commit: answered -> the answer as the result
\* (Rules.result/1); with the owner -> park on the signal alone; asked
\* with the carrier queued or placed -> park again with a new until;
\* asked with the carrier settled or withdrawn (Rules.escalate?/2) ->
\* escalate; withdrawn or missing -> an error result.
QResume(st) ==
    LET t == st.t
        nxt == CASE q[t] = "answered" -> "fin_ans"
                 [] q[t] = "with_owner" -> "park_sig"
                 [] q[t] = "asked" /\ qsub[t] \in {"queued", "placed"} -> "q_repark"
                 [] q[t] = "asked" -> "escalate"
                 [] OTHER -> "fin_err"
    IN
    /\ IsAsk(st) /\ st.phase = "resume" /\ st.pc = "go"
    /\ steps' = StepTo(st, nxt)
    /\ UNCHANGED <<dbVars, rowVars, ghostVars, timeVars, inc, faultVars, schedVars, askVars>>

\* Questions.escalate/1: its own commit, unfenced, which re-checks the
\* question and its carrier and, if Blip still hasn't handled it, passes
\* it to the owner ({:pass, :hub}, with a notice in Blip's conversation);
\* then the call parks on the signal alone.
QEscalate(st) ==
    LET t == st.t IN
    /\ IsAsk(st) /\ st.pc = "escalate"
    /\ q' = IF q[t] = "asked" /\ qsub[t] \in {"settled", "withdrawn"}
            THEN [q EXCEPT ![t] = "with_owner"] ELSE q
    /\ steps' = StepTo(st, "park_sig")
    /\ UNCHANGED <<dbVars, rowVars, ghostVars, timeVars, inc, faultVars, schedVars,
                   qsub, qGhosts, hookVars>>

---------------------------------------------------------------------------
(* The routine behind a schedule (schedules/routine.ex), and the owner's  *)
(* edits and deletes (schedules.ex).  The schedule's row is reduced to     *)
(* `carrier`, the routine its task_id names; times are left out (a wait's  *)
(* "until" passes at any moment: Tick).                                    *)

\* step("start"): sleep until the first time (Routine.first_wait/1)
RoutineStart(st) ==
    LET r == st.t IN
    /\ Kind(r) = "routine" /\ st.phase = "start" /\ st.pc = "go"
    /\ IF Ignored(st) THEN IgnoredCommit(st)
       ELSE /\ task' = WaitIn(task, r, {}, "none", TRUE, "fire", {}, 0)
            /\ untilPassed' = [untilPassed EXCEPT ![r] = FALSE]
            /\ steps' = StepDone(st)
            /\ UNCHANGED <<sub, toolResults, orphanCalls, nextGen, nextTool, nextOrd,
                           rowVars, ghostVars, rechecks, inc, faultVars, schedVars, askVars>>

\* The fence of the fire step's Runtime.commit: Ignored(st), or with
\* BugFireIgnoresAbort a fence that only checks the start token.
FireIgnored(st) ==
    IF BugFireIgnoresAbort
    THEN task[st.t].status # "running" \/ task[st.t].tok # st.tok
    ELSE Ignored(st)

\* Routine.after_fire/2 on the task table tk: wait for the next time (phase
\* "fire", checkpoint runs + 1), or finish once it has fired MaxFires times
\* (a one-off when MaxFires = 1).
AfterFire(tk, r, k) ==
    IF k < MaxFires
    THEN [WaitIn(tk, r, {}, "none", TRUE, "fire", {}, 0) EXCEPT ![r].fired = k]
    ELSE [FinishIn(tk, r, "done") EXCEPT ![r].fired = k]

\* step("fire"): one Runtime.commit that reads the row, applies Rules.fire/2
\* (left out: consent and the overlap rules only choose a skip over committed
\* state), records the outcome on the row, announces, and returns
\* after_fire/2.  With Target "conv" the firing is submit_tx of RS(r, k)
\* (Durable.submit_tx/4 through Threads.send_tx/4, or Blip's), deduped on
\* its request ID; with "thread" it is Threads.start_tx/4, a new thread in
\* another conversation with no request ID to dedupe on, so only `fires`
\* records it.  A row that is gone (carrier "none") finishes the task and
\* writes nothing ({:done, %{"gone" => true}}); with the fence intact that
\* commit can't land, which NoFireAfterRetire checks too.
RoutineFire(st) ==
    LET r == st.t
        k == st.fired + 1
        s == RS(r, k)
    IN
    /\ Kind(r) = "routine" /\ st.phase = "fire" /\ st.pc = "go"
    /\ IF FireIgnored(st) THEN IgnoredCommit(st)
       ELSE
       /\ steps' = StepDone(st)
       /\ lateFire' = (lateFire \/ retired[r])
       /\ IF carrier = "none"
          THEN /\ task' = FinishIn(task, r, "done")
               /\ UNCHANGED <<sub, nextGen, nextOrd, untilPassed, fires, dupFire>>
          ELSE /\ fires' = [fires EXCEPT ![r] = @ + 1]
               /\ dupFire' = (dupFire \/ fires[r] > st.fired)
               /\ untilPassed' = IF k < MaxFires THEN [untilPassed EXCEPT ![r] = FALSE]
                                 ELSE untilPassed
               /\ IF Target = "conv"
                  THEN /\ task' = AfterFire(SubmitTk(task, sub, s), r, k)
                       /\ sub' = SubmitSb(task, sub, s, "follow_up")
                       /\ nextGen' = SubmitGen(task, sub, s)
                       /\ nextOrd' = SubmitOrd(sub, s)
                  ELSE /\ task' = AfterFire(task, r, k)
                       /\ UNCHANGED <<sub, nextGen, nextOrd>>
       /\ UNCHANGED <<toolResults, orphanCalls, nextTool, rowVars, ghostVars, rechecks,
                      inc, faultVars, carrier, retired, edits, deletes, askVars>>

\* Schedules.update/3 (the project page's form), in one commit: the old
\* task is marked for abort, background included (Tx.request_abort/3 with
\* background: true; a no-op on a finished task), and a new routine is
\* armed and named on the row.  With BugEditKeepsOld the mark is skipped.
\* An edit of a one-off that already fired at the time it keeps arms
\* nothing (Rules.arm/4 says :finished) and changes nothing modeled here,
\* so it is left out.
OwnerEdit ==
    /\ edits < MaxEdits
    /\ carrier # "none"
    /\ \E n \in Spares : task[n].status = "none"
    /\ LET n   == CHOOSE x \in Spares : task[x].status = "none"
           tk1 == IF BugEditKeepsOld THEN task ELSE ReqAbort(task, carrier)
       IN  /\ task' = [tk1 EXCEPT ![n] = NewRoutine(n)]
           /\ carrier' = n
    /\ retired' = [retired EXCEPT ![carrier] = TRUE]
    /\ edits' = edits + 1
    /\ UNCHANGED <<sub, toolResults, orphanCalls, nextGen, nextTool, nextOrd, rowVars,
                   ghostVars, timeVars, procVars, faultVars, fires, lateFire, dupFire,
                   deletes, askVars>>

\* Schedules.delete/1 (and Blip's cancel_schedule, delete_tx/3), in one
\* commit: the task is marked for abort and the row deleted.
OwnerDelete ==
    /\ deletes < MaxDeletes
    /\ carrier # "none"
    /\ task' = ReqAbort(task, carrier)
    /\ carrier' = "none"
    /\ retired' = [retired EXCEPT ![carrier] = TRUE]
    /\ deletes' = deletes + 1
    /\ UNCHANGED <<sub, toolResults, orphanCalls, nextGen, nextTool, nextOrd, rowVars,
                   ghostVars, timeVars, procVars, faultVars, fires, lateFire, dupFire,
                   edits, askVars>>

StepAct(st) ==
    \/ GenRequest(st) \/ GenAfterTools(st)
    \/ MStart(st) \/ MPark(st) \/ MResume(st) \/ MRepark(st) \/ MClaim(st)
    \/ PlainRun(st) \/ ToolFinish(st)
    \/ QAsk(st) \/ QPark(st) \/ QParkSig(st) \/ QResume(st) \/ QEscalate(st)
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
                             off |-> task[id].off, fired |-> task[id].fired]}
    /\ UNCHANGED <<sub, toolResults, orphanCalls, nextGen, nextTool, nextOrd,
                   rowVars, ghostVars, timeVars, inc, faultVars, schedVars, askVars>>

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
                   rowVars, ghostVars, timeVars, procVars, faultVars, schedVars, askVars>>

\* stop_aborted/2, first half: terminate_child for a marked task whose step
\* this Scheduler is running (Policy.steps_to_kill/2).  A step that already
\* returned (result not yet handled) is not found, so nothing happens to it.
SchedKill(id) ==
    /\ task[id].abort /\ LiveIn(task, id)
    /\ \E st \in CurSteps(id) : st.pc # "exited" /\ steps' = steps \ {st}
    /\ UNCHANGED <<dbVars, rowVars, ghostVars, timeVars, inc, faultVars, schedVars, askVars>>

\* on_abort/on_fail hooks run in the commit that ends the task that way.
\* Generation settles its submissions and runs the settle hook
\* (Durable.settled/3 with "stopped" or "failed"); ToolTask records the
\* result, and the tool's on_interrupt/2 runs: a machine call cancels its
\* op (Call.on_interrupt/2 -> cancel_tx/2), an ask call withdraws its
\* question (Questions.withdraw_tx/2).
OnAbortSb(id, sb) ==
    IF Kind(id) = "gen" THEN Settle(sb, task[id].subs, "unanswered") ELSE sb
OnAbortTr(id) ==
    IF Kind(id) = "tool" THEN [toolResults EXCEPT ![id] = @ + 1] ELSE toolResults
OnAbortRow(id) == IF Kind(id) = "tool" THEN CancelRow(id) ELSE UNCHANGED <<row, rcx>>
OnAbortQ(id) == IF Kind(id) = "tool" THEN Withdraw(id) ELSE UNCHANGED qVars
OnAbortHook(id) ==
    IF Kind(id) = "gen" THEN RunHook(id, task[id].subs, sub) ELSE UNCHANGED hookVars

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
    /\ OnAbortQ(id)
    /\ OnAbortHook(id)
    /\ UNCHANGED <<orphanCalls, nextTool, nextOrd, signal, ghostVars, timeVars,
                   procVars, faultVars, schedVars, qGhosts>>

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
            /\ OnAbortQ(st.t)
            /\ OnAbortHook(st.t)
            /\ UNCHANGED <<orphanCalls, nextTool, nextOrd, signal>>
       ELSE UNCHANGED <<dbVars, rowVars, qVars, hookVars>>
    /\ UNCHANGED <<ghostVars, timeVars, inc, faultVars, schedVars, qGhosts>>

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
                   procVars, faultVars, schedVars, askVars>>

\* Assistant.stop -> Durable.abort/2: withdraw the user's queued input
\* (scheduled prompts stay, Submission.background?/1), mark the run.  This
\* is Blip's Stop; a thread's Stop (Threads.stop/1) withdraws scheduled
\* prompts too, which is the withdraw of any queued input.
UserAbort ==
    /\ aborts < MaxAborts
    /\ aborts' = aborts + 1
    /\ sub' = [x \in SubIds |-> IF sub[x].status = "queued" /\ x \in Users
                                THEN [sub[x] EXCEPT !.status = "withdrawn"] ELSE sub[x]]
    /\ task' = IF IdleIn(task) THEN task
               ELSE ReqAbort(task, CHOOSE r \in ActiveRunsIn(task) : TRUE)
    /\ UNCHANGED <<toolResults, orphanCalls, nextGen, nextTool, nextOrd, rowVars,
                   ghostVars, timeVars, procVars, hubCrashes, schedCrashes, stepCrashes, schedVars, askVars>>

\* The machine's terminal snapshot: Machines.snapshot/3 with
\* Rules.on_snapshot/3 (hub rule 4) in one Store commit: an open row
\* becomes finished with the result, or closed if it was canceled, and the
\* op's signal fires.  The node may report at any time once the row exists.
OpFinish(t) ==
    /\ row[t] = "open"
    /\ row' = [row EXCEPT ![t] = IF rcx[t] THEN "closed" ELSE "finished"]
    /\ signal' = [signal EXCEPT ![t] = TRUE]
    /\ UNCHANGED <<dbVars, rcx, ghostVars, timeVars, procVars, faultVars, schedVars, askVars>>

\* A waiting task's deadline passes; the Scheduler's timer (arm_timer/1,
\* Policy.timer_delay/2) then reconciles.  A tool call's rechecks are
\* bounded (MaxRechecks), except an ask call's once its carrier has
\* settled: then the next check escalates or stops checking, so the
\* escalation is always reached (without the exception a model run could
\* spend the budget while the carrier is still queued).
AskCheckDue(id) == task[id].ttype = "ask" /\ qsub[id] \in {"settled", "withdrawn"}
Tick(id) ==
    /\ task[id].status = "waiting" /\ task[id].wUntil /\ ~untilPassed[id]
    /\ Kind(id) = "tool" => (rechecks[id] < MaxRechecks \/ AskCheckDue(id))
    /\ untilPassed' = [untilPassed EXCEPT ![id] = TRUE]
    /\ UNCHANGED <<dbVars, rowVars, ghostVars, rechecks, procVars, faultVars, schedVars, askVars>>

---------------------------------------------------------------------------
(* Blip's side of a question.  Blip's conversation is reduced to the       *)
(* question's carrier: a Blip run places it, and the run settles it        *)
(* whether or not Blip acted (it answered, passed it on, replied in prose, *)
(* failed, hit the round limit, or the owner stopped it; Blip's Stop keeps *)
(* a queued carrier, which is background input, Submission.background?/1). *)
(* Merging a question into a queued carrier is one commit that edits a     *)
(* queued row, so it is this carrier too.  Blip's tools may name the       *)
(* question at any time after it was asked, since list_threads and         *)
(* read_thread show open questions, so its answer and pass are not tied to *)
(* the carrier being placed.  Refused steps write nothing and are left     *)
(* out.                                                                    *)

\* Rules.step/2 accepting an answer: Blip's answer_question while Blip has
\* the question ({:blip, _}), or while it is with the owner when the owner
\* typed into Blip's run ({:blip, true}, Blip relaying what they said; the
\* refusal of {:blip, false} is pure and not modeled); the owner's own
\* answer only while the question is with them.
BlipMayAnswer(st)  == st \in {"asked", "with_owner"}
OwnerMayAnswer(st) == st = "with_owner" \/ (BugAnswerAnyStatus /\ st # "none")

\* Questions.answer_tx/4: the status, the answer, and the signal
\* "question:<id>" that wakes the call, in one commit.  The bug switch can
\* answer again, so answers is bounded to keep the state space finite.
Answer(t) ==
    /\ answers[t] < 2
    /\ q' = [q EXCEPT ![t] = "answered"]
    /\ signal' = [signal EXCEPT ![t] = TRUE]
    /\ answers' = [answers EXCEPT ![t] = @ + 1]
    /\ lateAnswer' = (lateAnswer \/ q[t] = "withdrawn")
    /\ UNCHANGED <<dbVars, row, rcx, ghostVars, timeVars, procVars, faultVars, schedVars,
                   qsub, asks, qResult, hookVars>>

\* A Blip run places the carrier (Inbox.next_input/1 once Blip's run ends,
\* or at once when Blip was idle), and that run settles it.
BlipPlace(t) ==
    /\ qsub[t] = "queued"
    /\ qsub' = [qsub EXCEPT ![t] = "placed"]
    /\ UNCHANGED <<dbVars, rowVars, ghostVars, timeVars, procVars, faultVars, schedVars,
                   q, qGhosts, hookVars>>
BlipSettle(t) ==
    /\ qsub[t] = "placed"
    /\ qsub' = [qsub EXCEPT ![t] = "settled"]
    /\ UNCHANGED <<dbVars, rowVars, ghostVars, timeVars, procVars, faultVars, schedVars,
                   q, qGhosts, hookVars>>

\* answer_question: {:commit, fn tx -> Questions.answer_tx(tx, id, text,
\* {:blip, owner_wrote?}) end}
BlipAnswer(t) == BlipMayAnswer(q[t]) /\ Answer(t)

\* ask_owner: Questions.pass_tx/4 with {:pass, :blip}
BlipPass(t) ==
    /\ q[t] = "asked"
    /\ q' = [q EXCEPT ![t] = "with_owner"]
    /\ UNCHANGED <<dbVars, rowVars, ghostVars, timeVars, procVars, faultVars, schedVars,
                   qsub, qGhosts, hookVars>>

\* Questions.answer/2 from Blip's card, the home page or the thread page:
\* answer_tx/4 with {:answer, :owner} (and Signals.answer_tx/3, which only
\* writes into Blip's conversation).  BugAnswerAnyStatus skips the status
\* check.
OwnerAnswer(t) == OwnerMayAnswer(q[t]) /\ Answer(t)

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
                   rowVars, ghostVars, timeVars, inc, schedCrashes, stepCrashes, aborts, schedVars, askVars>>

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
                   rowVars, ghostVars, timeVars, hubCrashes, stepCrashes, aborts, schedVars, askVars>>

\* A step exits abnormally before finishing (the :DOWN path), or, in a
\* machine or ask call's own code, raises: ToolTask rescues the raise and
\* records an error result, whose commit runs on_interrupt/2 (hub rule 10;
\* for an ask call, the withdraw).
RaisePcs    == {"go", "park", "repark_on", "repark_off"}
AskRaisePcs == {"go", "park", "q_repark", "escalate", "park_sig"}
StepCrash(st) ==
    /\ stepCrashes < MaxStepCrashes
    /\ st.pc # "exited"
    /\ stepCrashes' = stepCrashes + 1
    /\ \/ steps' = StepExit(st)
       \/ IsMachine(st) /\ st.pc \in RaisePcs /\ steps' = StepTo(st, "fin_err")
       \/ IsAsk(st) /\ st.pc \in AskRaisePcs /\ steps' = StepTo(st, "fin_err")
    /\ UNCHANGED <<dbVars, rowVars, ghostVars, timeVars, inc, hubCrashes, schedCrashes, aborts,
                   schedVars, askVars>>

---------------------------------------------------------------------------

Init ==
    /\ task = [id \in TaskIds |-> IF id \in Routines THEN NewRoutine(id) ELSE NoTask(id)]
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
    /\ carrier = IF Routines = {} THEN "none" ELSE CHOOSE r \in Routines : TRUE
    /\ fires = [r \in RoutineIds |-> 0]
    /\ retired = [r \in RoutineIds |-> FALSE]
    /\ lateFire = FALSE /\ dupFire = FALSE
    /\ edits = 0 /\ deletes = 0
    /\ q = [t \in ToolIds |-> "none"]
    /\ qsub = [t \in ToolIds |-> "none"]
    /\ asks = [t \in ToolIds |-> 0]
    /\ answers = [t \in ToolIds |-> 0]
    /\ lateAnswer = FALSE
    /\ qResult = [t \in ToolIds |-> FALSE]
    /\ hooked = {}
    /\ dupHook = FALSE

Next ==
    \/ \E u \in Users : UserSubmit(u)
    \/ UserAbort
    \/ OwnerEdit
    \/ OwnerDelete
    \/ \E id \in TaskIds : SchedStart(id)
    \/ \E id \in TaskIds : SchedWake(id)
    \/ \E id \in TaskIds : SchedKill(id)
    \/ \E id \in TaskIds : SchedAbort(id)
    \/ \E st \in steps : SchedExit(st)
    \/ \E st \in steps : StepAct(st)
    \/ \E st \in steps : StepCrash(st)
    \/ \E t \in ToolIds : OpFinish(t)
    \/ \E t \in ToolIds : BlipPlace(t) \/ BlipSettle(t) \/ BlipAnswer(t) \/ BlipPass(t)
    \/ \E t \in ToolIds : OwnerAnswer(t)
    \/ \E id \in TaskIds : Tick(id)
    \/ HubCrash
    \/ SchedCrash

\* What the implementation guarantees: the Scheduler reconciles after every
\* commit touching tasks or signals, after every step result or :DOWN, and
\* on its timer, so each of its actions is weakly fair; step processes keep
\* running; time passes; and an op eventually ends on its machine (the
\* command finishes, or is canceled, once the machine is back; there is no
\* timeout on a running command, so without this a call may wait for
\* good).  Blip's conversation moves on too: a queued carrier is placed
\* once Blip's current run ends, and a placed one settles when that run
\* does (this spec checks both for the modeled conversation:
\* QueuedNotStranded, PlacedSettles).  Whether Blip answers or passes a
\* question is its choice, so those get no fairness.  The user, the
\* owner's answers, edits and deletes, and faults get no fairness.
SysNext ==
    \/ \E id \in TaskIds : SchedStart(id) \/ SchedWake(id) \/ SchedKill(id) \/ SchedAbort(id)
    \/ \E st \in steps : SchedExit(st) \/ StepAct(st)
    \/ \E id \in TaskIds : Tick(id)
    \/ \E t \in ToolIds : OpFinish(t) \/ BlipPlace(t) \/ BlipSettle(t)

StepOf(id) == \E st \in steps : st.t = id /\ StepAct(st)
ExitOf(id) == \E st \in steps : st.t = id /\ SchedExit(st)

\* Per-action weak fairness, as the implementation provides.
FairnessFine ==
    /\ \A id \in TaskIds :
         /\ WF_vars(SchedStart(id)) /\ WF_vars(SchedWake(id))
         /\ WF_vars(SchedKill(id))  /\ WF_vars(SchedAbort(id))
         /\ WF_vars(ExitOf(id))     /\ WF_vars(StepOf(id))
         /\ WF_vars(Tick(id))
    /\ \A t \in ToolIds : WF_vars(OpFinish(t)) /\ WF_vars(BlipPlace(t)) /\ WF_vars(BlipSettle(t))

\* One weak-fairness condition on all system actions.  This is weaker than
\* FairnessFine (it allows more behaviors), so a liveness property that holds
\* under it also holds under FairnessFine; it only rules out stopping while
\* the system can still move.  It is much cheaper for TLC.
Fairness == WF_vars(SysNext)

Spec     == Init /\ [][Next]_vars /\ Fairness
SpecFine == Init /\ [][Next]_vars /\ FairnessFine

\* A question with the owner waits for them with no time limit, by design
\* (docs/decisions.md#signals-and-questions), and so does the thread's run
\* around it. Liveness of that run (PlacedSettles with an ask call) holds
\* only if the owner eventually answers a question passed to them, or stops
\* the thread.
OwnerAnswers      == \A t \in ToolIds : WF_vars(OwnerAnswer(t))
SpecOwnerAnswers  == Spec /\ OwnerAnswers

-----------------------------------------------------------------------------
(* Properties *)

TaskStatuses == {"none", "pending", "running", "waiting"} \cup Terminal
QStatuses       == {"none", "asked", "with_owner", "answered", "withdrawn"}
CarrierStatuses == {"none", "queued", "placed", "settled", "withdrawn"}
SubStatuses  == {"none", "queued", "placed", "done", "unanswered", "withdrawn"}

TypeOK ==
    /\ \A id \in TaskIds : task[id].status \in TaskStatuses
    /\ \A s \in SubIds : sub[s].status \in SubStatuses
    /\ \A t \in ToolIds : row[t] \in {"none", "open", "finished", "closed"}
    /\ nextGen \in 1..(NGen + 1) /\ nextTool \in 1..(NTools + 1)
    /\ \A st \in steps : st.t \in TaskIds
    /\ carrier \in RoutineIds \cup {"none"}
    /\ \A r \in RoutineIds : fires[r] \in Nat
    /\ \A t \in ToolIds : q[t] \in QStatuses /\ qsub[t] \in CarrierStatuses

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

\* Blip's Stop withdraws only the user's own queued input: a scheduled
\* prompt stays.
BackgroundNotWithdrawn == \A s \in RSIds : sub[s].status # "withdrawn"

\* At most one routine is live and not marked for abort, and it is the one
\* the schedule's row names: an edit or delete never leaves the old timer
\* running beside the new one.
OneCarrier ==
    \A r \in RoutineIds : LiveIn(task, r) /\ ~task[r].abort => r = carrier

\* No fire step's commit lands for a routine after the commit that retired
\* it (an edit or delete): the step fence alone stops a firing that was in
\* flight.
NoFireAfterRetire == ~lateFire

\* No two firing commits for the same routine and checkpoint, across hub
\* crashes, Scheduler restarts and step crashes; with Target "thread" there
\* is no request ID to fall back on.
FireOncePerSlot == ~dupFire

\* An ask call has at most one question row: a rerun finds it by task_id.
OneQuestionPerCall == \A t \in ToolIds : asks[t] <= 1

\* Once an ask call has ended, however it ended, its question is not open:
\* nothing would ever answer it, and it would sit on the home page for
\* good (the ask's own fence, Rules.askable?/1, and on_interrupt/2).
NoOpenQuestionAfterCall ==
    \A t \in ToolIds : task[t].status \in Terminal => q[t] \notin {"asked", "with_owner"}

\* One answer per question, from Blip or the owner.
AnswerOnce == \A t \in ToolIds : answers[t] <= 1

\* No answer is accepted after the question was withdrawn.
NoAnswerAfterWithdraw == ~lateAnswer

\* An ask call that ended with an answer has an answered question.
AnsweredResult == \A t \in ToolIds : qResult[t] => q[t] = "answered"

\* The settle hook runs once per settle: no submission is reported settled
\* twice, and no generation settles twice with nothing to close.
HookOnce == ~dupHook

\* Liveness

\* An answer reaches a call that is still waiting for it.
AnsweredCallEnds ==
    \A t \in ToolIds : (q[t] = "answered" /\ task[t].status = "waiting")
                         ~> task[t].status \in Terminal

\* A question whose carrier settled while Blip still had it (Blip's run
\* ended without answering or passing it) reaches the owner, or closes.
UnhandledReachesOwner ==
    \A t \in ToolIds : (q[t] = "asked" /\ qsub[t] = "settled") ~> q[t] # "asked"

\* Once the call has ended its question is closed (or was never asked).
\* Immediate today, since on_interrupt/2 runs in the ending commit; stated
\* so a later change can't break it.
CallEndClosesQuestion ==
    \A t \in ToolIds : task[t].status \in Terminal ~> q[t] \notin {"asked", "with_owner"}

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

\* A routine retired while it was live (marked for abort by the edit or
\* delete) ends aborted.
RetiredEnds ==
    \A r \in RoutineIds : (retired[r] /\ LiveIn(task, r)) ~> task[r].status = "aborted"

=============================================================================
