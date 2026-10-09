------------------------------ MODULE HubOps ------------------------------
(***************************************************************************)
(* The hub-node operation protocol of build step 1, whose rules are now in *)
(* docs/operations.md: a machine tool call on the hub (shell), its op row, *)
(* the websocket, and the node's executor, journal and op processes.       *)
(* HubOps.md maps every action to the code and lists what TLC found.       *)
(*                                                                         *)
(* One machine. Calls are tool calls on it; call c owns op c (op IDs are  *)
(* derived from the tool task's ID, so a rerun of the call reuses its op  *)
(* and two calls never share one).                                         *)
(*                                                                         *)
(* Hub, durable (SQLite through Durable.Store)                             *)
(*   row     machine_ops: st, conf (confirmed), cx (cancel), psh (op.start *)
(*           pushed at least once), snap                                   *)
(*   sig     the "op:<id>" signal                                          *)
(*   tst, tph, abReq, offS, tres, nres   the durable tool task: status,   *)
(*           phase (execute or resume), abort requested, offline_since    *)
(*           set, its tool result, how many results were recorded          *)
(* Hub, memory                                                             *)
(*   step    the tool task's step process: "ins" (Machines.start's        *)
(*           commit), "send" (asking the channel to push), "park" (the    *)
(*           {:wait} commit), "res" (resume/2 reading the row and the     *)
(*           registry), "rc" (resume/2's commit)                           *)
(*   ron     whether the machine was online when resume/2 read it         *)
(*   skn     the known flag the step read in its commit (stale-start bug) *)
(*   orph, okn  a step left running by a Scheduler-only crash              *)
(*   pend    a commit that ends the call and may send op.cancel from     *)
(*           inside (Stop, an error, the offline limit) is in progress,   *)
(*           holding the result it records; "-" when none. Store commits  *)
(*           are one line, so every other commit waits (Busy)              *)
(*   chan    the machine's NodeChannel: none, up, or stale (registered,   *)
(*           its socket gone)                                              *)
(*   cq      the channel's mailbox: requests from other processes         *)
(*   hpend   a terminal snapshot acked but not committed (ack-early bug)  *)
(* Wire: h2n (hub to node), n2h (node to hub); FIFO per connection, lost  *)
(*   when it drops                                                         *)
(* Node                                                                    *)
(*   conn    the Connection: down, joining (join reply not handled yet),  *)
(*           up                                                            *)
(*   fq      the Connection's mailbox: snapshots the executor forwarded   *)
(*   jr      the journal, <data_dir>/ops/<id>/op.json: st, cx              *)
(*   proc    the op process: "ck" (about to ask for its process           *)
(*           checkpoint), "go" (checkpoint journaled, about to spawn),    *)
(*           "jw" (spawned, checkpoint not journaled: bug only), "wait"   *)
(*           (command spawned, waiting for it)                             *)
(*   pcx     the op process has been told to cancel                        *)
(*   cmd     the OS command: none, running, exited, killed (by a cancel), *)
(*           lost (killed by a node restart)                               *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS
    N,                \* number of tool calls (Calls = 1..N)
    MaxDisconnects,   \* websocket drops
    MaxHubCrashes,    \* hub VM restarts
    MaxSchedCrashes,  \* Scheduler-only crashes (its steps keep running)
    MaxNodeRestarts,  \* node VM restarts
    MaxWipes,         \* node data directory lost (reinstall, disk reset)
    MaxStops,         \* user Stops
    MaxErrors,        \* tool steps that end their call with an error (a raise)
    MaxRepush,        \* op.start re-pushes from online re-parks (hub rule 11)
    CmdsEnd,          \* TRUE: commands exit on their own eventually
    Bugs              \* what-if switches that put back a defect (see .md)

Calls == 1..N

BugNames == {"stale-start", "cancel-unjournaled", "unserialized-read",
             "keep-finished", "unfenced-insert",
             "ack-early", "spawn-before-journal", "start-after-cancel",
             "no-known", "abandon-silent", "offline-by-confirmed",
             "error-skips-cancel"}

ASSUME Bugs \subseteq BugNames

Bug(b) == b \in Bugs

VARIABLES
    row, sig, tst, tph, abReq, offS, tres, nres,
    step, skn, orph, okn, pend, ron, chan, cq, hpend,
    h2n, n2h,
    conn, fq, jr, proc, pcx, cmd,
    execs, nodeCx, cxEver, runCx, startCx, everJ, exitOk, wipeConf, preWipe,
    nDisc, nHub, nSched, nNode, nWipe, nStop, nErr, nRep

hubDb   == <<row, sig, tst, tph, abReq, offS, tres, nres>>
hubMem  == <<step, skn, orph, okn, pend, ron, chan, cq, hpend>>
wire    == <<h2n, n2h>>
nodeV   == <<conn, fq, jr, proc, pcx, cmd>>
ghost   == <<execs, nodeCx, cxEver, runCx, startCx, everJ, exitOk, wipeConf, preWipe>>
budget  == <<nDisc, nHub, nSched, nNode, nWipe, nStop, nErr, nRep>>
vars    == <<hubDb, hubMem, wire, nodeV, ghost, budget>>

-----------------------------------------------------------------------------
(* Helpers *)

Terminal == {"completed", "failed", "canceled", "lost"}
Results  == Terminal \cup {"stopped", "error", "offline-norun", "offline-maybe", "guard"}

NoRow  == [st |-> "none", conf |-> FALSE, cx |-> FALSE, psh |-> FALSE, snap |-> "-"]
NoJr   == [st |-> "none", cx |-> FALSE]

\* Every Store commit and every Store read waits while another commit runs.
Busy == \E c \in Calls : pend[c] # "-"

\* Photon.Machines.status/1: the registry has a channel for the machine.
Online == chan # "none"

\* Executor: journal, then forward to the Connection (dropped at once if
\* the Connection is down; see the .md on the Connection's mailbox).
Fwd(c, s) == fq' = IF conn = "down" THEN fq ELSE Append(fq, <<c, s>>)

\* What a channel's join pushes for the open rows (rule 2, rule 7).
JoinFor(k) ==
    IF row[k].st # "open" THEN <<>>
    ELSE IF row[k].cx
         THEN IF Bug("start-after-cancel")
              THEN << <<"start", k, row[k].conf>>, <<"cancel", k, FALSE>> >>
              ELSE << <<"cancel", k, FALSE>> >>
         ELSE << <<"start", k, row[k].conf>> >>
JoinPushes == LET js[k \in 0..N] == IF k = 0 THEN <<>> ELSE js[k - 1] \o JoinFor(k)
              IN js[N]

\* What the node's join pushes: every journaled snapshot.
SnapFor(k) == IF jr[k].st # "none" THEN << <<k, jr[k].st>> >> ELSE <<>>
JournalSnaps == LET js[k \in 0..N] == IF k = 0 THEN <<>> ELSE js[k - 1] \o SnapFor(k)
                IN js[N]

\* The request Machines.start sends the channel after its commit. Fixed:
\* "push op c as its row is now". Plan as written: the op.start built from
\* the row the commit read.
Req(c, k) == IF Bug("stale-start") THEN <<"start", c, k>> ELSE <<"pstart", c, FALSE>>

\* Machines.start's insert (on_conflict: :nothing). Fixed: only while the
\* tool task is unfinished and not marked for abort.
Insert(c) ==
    row' = IF row[c].st = "none"
              /\ (Bug("unfenced-insert") \/ (tst[c] # "done" /\ ~abReq[c]))
           THEN [row EXCEPT ![c] = [NoRow EXCEPT !.st = "open"]]
           ELSE row
KnownAfterInsert(c) == IF row[c].st = "none" THEN FALSE ELSE row[c].conf

\* Rule 4: a terminal snapshot for an open row, one commit with the signal.
Finish(c, s) ==
    /\ row' = [row EXCEPT ![c] = [st   |-> IF row[c].cx THEN "closed" ELSE "finished",
                                  conf |-> TRUE,
                                  cx   |-> row[c].cx,
                                  psh  |-> row[c].psh,
                                  snap |-> IF row[c].cx THEN "-" ELSE s]]
    /\ sig' = [sig EXCEPT ![c] = TRUE]

Spawn(c) ==
    /\ cmd' = [cmd EXCEPT ![c] = "running"]
    /\ execs' = [execs EXCEPT ![c] = @ + 1]

-----------------------------------------------------------------------------
Init ==
    /\ row = [c \in Calls |-> NoRow]
    /\ sig = [c \in Calls |-> FALSE]
    /\ tst = [c \in Calls |-> "none"]
    /\ tph = [c \in Calls |-> "exec"]
    /\ abReq = [c \in Calls |-> FALSE]
    /\ offS = [c \in Calls |-> FALSE]
    /\ tres = [c \in Calls |-> "-"]
    /\ nres = [c \in Calls |-> 0]
    /\ step = [c \in Calls |-> "none"]
    /\ skn = [c \in Calls |-> FALSE]
    /\ orph = [c \in Calls |-> "none"]
    /\ okn = [c \in Calls |-> FALSE]
    /\ pend = [c \in Calls |-> "-"]
    /\ ron = [c \in Calls |-> FALSE]
    /\ chan = "none" /\ cq = <<>> /\ hpend = <<>>
    /\ h2n = <<>> /\ n2h = <<>>
    /\ conn = "down" /\ fq = <<>>
    /\ jr = [c \in Calls |-> NoJr]
    /\ proc = [c \in Calls |-> "none"]
    /\ pcx = [c \in Calls |-> FALSE]
    /\ cmd = [c \in Calls |-> "none"]
    /\ execs = [c \in Calls |-> 0]
    /\ nodeCx = [c \in Calls |-> FALSE]
    /\ cxEver = [c \in Calls |-> FALSE]
    /\ runCx = [c \in Calls |-> FALSE]
    /\ startCx = [c \in Calls |-> FALSE]
    /\ everJ = [c \in Calls |-> FALSE]
    /\ exitOk = [c \in Calls |-> FALSE]
    /\ wipeConf = [c \in Calls |-> FALSE]
    /\ preWipe = [c \in Calls |-> 0]
    /\ nDisc = 0 /\ nHub = 0 /\ nSched = 0 /\ nNode = 0 /\ nWipe = 0 /\ nStop = 0
    /\ nErr = 0 /\ nRep = 0

-----------------------------------------------------------------------------
(* Hub: the tool call (Photon.MachineTools.Call under Durable.ToolTask) *)

\* The model calls shell: ToolTask commits the call's intent (a task).
CallStart(c) ==
    /\ tst[c] = "none" /\ ~Busy
    /\ tst' = [tst EXCEPT ![c] = "pending"]
    /\ UNCHANGED <<row, sig, tph, abReq, offS, tres, nres, hubMem, wire, nodeV, ghost, budget>>

\* Scheduler starts the task: execute/2 for a new call or a rerun
\* (replay: :safe), resume/2 for a call that was woken.
SchedStart(c) ==
    /\ tst[c] = "pending" /\ ~abReq[c] /\ ~Busy
    /\ tst' = [tst EXCEPT ![c] = "running"]
    /\ step' = [step EXCEPT ![c] = IF tph[c] = "exec" THEN "ins" ELSE "res"]
    /\ UNCHANGED <<row, sig, tph, abReq, offS, tres, nres,
                   skn, orph, okn, pend, ron, chan, cq, hpend, wire, nodeV, ghost, budget>>

\* execute/2 step 5: Machines.start/1 commits the op row (its own Store
\* commit, not fenced by the task) ...
ExecIns(c) ==
    /\ step[c] = "ins" /\ ~Busy
    /\ Insert(c)
    /\ skn' = [skn EXCEPT ![c] = KnownAfterInsert(c)]
    /\ step' = [step EXCEPT ![c] = "send"]
    /\ UNCHANGED <<sig, tst, tph, abReq, offS, tres, nres,
                   orph, okn, pend, ron, chan, cq, hpend, wire, nodeV, ghost, budget>>

\* ... then asks the machine's channel to push ({:push_op, id}). A stale
\* channel loses it; with no channel nothing is sent.
ExecSend(c) ==
    /\ step[c] = "send"
    /\ cq' = IF chan = "up" THEN Append(cq, Req(c, skn[c])) ELSE cq
    /\ step' = [step EXCEPT ![c] = "park"]
    /\ UNCHANGED <<hubDb, skn, orph, okn, pend, ron, chan, hpend, wire, nodeV, ghost, budget>>

\* execute/2 step 6: {:wait, signal + until}, offline_since from status/1.
\* A step's commit is ignored if the task was marked for abort.
ExecPark(c) ==
    /\ step[c] = "park" /\ ~Busy
    /\ step' = [step EXCEPT ![c] = "none"]
    /\ IF abReq[c]
       THEN UNCHANGED <<tst, tph, offS>>
       ELSE /\ tst' = [tst EXCEPT ![c] = "waiting"]
            /\ tph' = [tph EXCEPT ![c] = "resume"]
            /\ offS' = [offS EXCEPT ![c] = ~Online]
    /\ UNCHANGED <<row, sig, abReq, tres, nres, skn, orph, okn, pend, ron, chan, cq, hpend,
                   wire, nodeV, ghost, budget>>

\* The parked call wakes: its signal was recorded, or its "until" passed
\* (the 60-second check). Time passing is not modeled beyond this.
Wake(c) ==
    /\ tst[c] = "waiting" /\ ~abReq[c] /\ ~Busy
    /\ tst' = [tst EXCEPT ![c] = "running"]
    /\ step' = [step EXCEPT ![c] = "res"]
    /\ UNCHANGED <<row, sig, tph, abReq, offS, tres, nres,
                   skn, orph, okn, pend, ron, chan, cq, hpend, wire, nodeV, ghost, budget>>

Done(c, r) ==
    /\ tst' = [tst EXCEPT ![c] = "done"]
    /\ tres' = [tres EXCEPT ![c] = r]
    /\ nres' = [nres EXCEPT ![c] = @ + 1]

Repark(c, off) ==
    /\ tst' = [tst EXCEPT ![c] = "waiting"]
    /\ offS' = [offS EXCEPT ![c] = off]
    /\ UNCHANGED <<row, tres, nres>>

\* resume/2 reads whether the machine is online (the registry, outside any
\* commit), then returns the commit that decides on the row as it is then.
\* Two steps: the node can join in between.
ResumeRead(c) ==
    /\ step[c] = "res"
    /\ step' = [step EXCEPT ![c] = "rc"]
    /\ ron' = [ron EXCEPT ![c] = Online]
    /\ UNCHANGED <<hubDb, skn, orph, okn, pend, chan, cq, hpend, wire, nodeV, ghost, budget>>

\* The offline result abandon_tx picks from the fresh row (hub rule 7):
\* "didn't run" only if op.start was never pushed. The plan as first
\* written went by confirmed alone.
OfflineResult(c) ==
    IF IF Bug("offline-by-confirmed") THEN row[c].conf ELSE row[c].psh \/ row[c].conf
    THEN "offline-maybe" ELSE "offline-norun"

ResumeCommit(c) ==
    /\ step[c] = "rc" /\ ~Busy
    /\ step' = [step EXCEPT ![c] = "none"]
    /\ IF abReq[c]
       THEN UNCHANGED <<row, tst, offS, tres, nres, pend, cq, nRep>>   \* commit ignored
       ELSE CASE row[c].st = "finished" ->
                   \* claim_tx: closed, snapshot dropped, the result
                   /\ row' = [row EXCEPT ![c].st = "closed", ![c].snap = "-"]
                   /\ Done(c, row[c].snap)
                   /\ UNCHANGED <<offS, pend, cq, nRep>>
              [] row[c].st = "open" /\ ron[c] ->
                   \* online: re-park, and ask the channel to push the op
                   \* again (hub rule 11), within the re-push budget
                   /\ Repark(c, FALSE)
                   /\ IF chan = "up" /\ nRep < MaxRepush
                      THEN /\ cq' = Append(cq, <<"pstart", c, FALSE>>)
                           /\ nRep' = nRep + 1
                      ELSE UNCHANGED <<cq, nRep>>
                   /\ UNCHANGED pend
              [] row[c].st = "open" /\ ~offS[c] ->
                   Repark(c, TRUE) /\ UNCHANGED <<pend, cq, nRep>>
              [] row[c].st = "open" ->
                   \* offline at two checks: the limit may have passed
                   \/ Repark(c, TRUE) /\ UNCHANGED <<pend, cq, nRep>>
                   \/ \* abandon_tx: sets cancel and, if a channel is
                      \* registered now, sends op.cancel from inside the
                      \* commit, like cancel_tx. Visible at CommitEnd.
                      /\ pend' = [pend EXCEPT ![c] = OfflineResult(c)]
                      /\ cq' = IF chan = "up" /\ ~Bug("abandon-silent")
                               THEN Append(cq, <<"cancel", c, FALSE>>) ELSE cq
                      /\ UNCHANGED <<row, tst, offS, tres, nres, nRep>>
              [] OTHER ->
                   \* closed, or no row: the guard result
                   /\ Done(c, "guard") /\ UNCHANGED <<row, offS, pend, cq, nRep>>
    /\ UNCHANGED <<sig, tph, abReq, skn, orph, okn, ron, chan, hpend,
                   wire, nodeV, ghost, nDisc, nHub, nSched, nNode, nWipe, nStop, nErr>>

\* A step ends its call with an error before its own commit: a raise that
\* ToolTask rescues, or an error result Call returns once the op ID is
\* known. Fixed (hub rule 10): the commit that records the error runs
\* on_interrupt -> cancel_tx, like a Stop. Bug: it only records the error.
StepError(c) ==
    /\ step[c] \in {"ins", "send", "park", "res", "rc"} /\ ~abReq[c] /\ ~Busy
    /\ nErr < MaxErrors
    /\ nErr' = nErr + 1
    /\ step' = [step EXCEPT ![c] = "none"]
    /\ IF Bug("error-skips-cancel")
       THEN /\ Done(c, "error")
            /\ UNCHANGED <<pend, cq>>
       ELSE /\ cq' = IF row[c].st = "open" /\ chan = "up"
                     THEN Append(cq, <<"cancel", c, FALSE>>) ELSE cq
            /\ pend' = [pend EXCEPT ![c] = "error"]
            /\ UNCHANGED <<tst, tres, nres>>
    /\ UNCHANGED <<row, sig, tph, abReq, offS, skn, orph, okn, ron, chan, hpend,
                   wire, nodeV, ghost, nDisc, nHub, nSched, nNode, nWipe, nStop, nRep>>

\* The user presses Stop: Durable.abort marks the task.
UserStop(c) ==
    /\ tst[c] \in {"pending", "running", "waiting"} /\ ~abReq[c]
    /\ nStop < MaxStops /\ ~Busy
    /\ abReq' = [abReq EXCEPT ![c] = TRUE]
    /\ nStop' = nStop + 1
    /\ UNCHANGED <<row, sig, tst, tph, offS, tres, nres, hubMem, wire, nodeV, ghost,
                   nDisc, nHub, nSched, nNode, nWipe, nErr, nRep>>

\* Scheduler.stop_aborted: kill the step, then the abort commit, which runs
\* on_abort -> on_interrupt -> Machines.cancel_tx. cancel_tx sends
\* op.cancel to an online machine from inside the commit, so the channel
\* may push it before the commit is visible. Split in two: the send (and
\* the commit's start), then CommitEnd.
SchedAbort1(c) ==
    /\ abReq[c] /\ tst[c] \in {"pending", "running", "waiting"} /\ ~Busy
    /\ step' = [step EXCEPT ![c] = "none"]
    /\ cq' = IF row[c].st = "open" /\ chan = "up"
             THEN Append(cq, <<"cancel", c, FALSE>>) ELSE cq
    /\ pend' = [pend EXCEPT ![c] = "stopped"]
    /\ UNCHANGED <<hubDb, skn, orph, okn, ron, chan, hpend, wire, nodeV, ghost, budget>>

\* The second half of a commit that ends the call and may have sent
\* op.cancel (Stop, an error, the offline limit): the result, and
\* cancel_tx's row change. An offline abandon only starts while the row is
\* open, and nothing commits in between, so it sets cancel too.
CommitEnd(c) ==
    /\ pend[c] # "-"
    /\ pend' = [pend EXCEPT ![c] = "-"]
    /\ Done(c, pend[c])
    /\ row' = CASE row[c].st = "open" -> [row EXCEPT ![c].cx = TRUE]
                [] row[c].st = "finished" /\ ~Bug("keep-finished") ->
                     [row EXCEPT ![c].st = "closed", ![c].snap = "-"]
                [] OTHER -> row
    /\ UNCHANGED <<sig, tph, abReq, offS, step, skn, orph, okn, ron, chan, cq, hpend,
                   wire, nodeV, ghost, budget>>

\* A step orphaned by a Scheduler-only crash keeps running; its fenced
\* commits are ignored, but Machines.start's commit and send are not fenced.
OrphIns(c) ==
    /\ orph[c] = "ins" /\ ~Busy
    /\ Insert(c)
    /\ okn' = [okn EXCEPT ![c] = KnownAfterInsert(c)]
    /\ orph' = [orph EXCEPT ![c] = "send"]
    /\ UNCHANGED <<sig, tst, tph, abReq, offS, tres, nres,
                   step, skn, pend, ron, chan, cq, hpend, wire, nodeV, ghost, budget>>

OrphSend(c) ==
    /\ orph[c] = "send"
    /\ cq' = IF chan = "up" THEN Append(cq, Req(c, okn[c])) ELSE cq
    /\ orph' = [orph EXCEPT ![c] = "none"]
    /\ UNCHANGED <<hubDb, step, skn, okn, pend, ron, chan, hpend, wire, nodeV, ghost, budget>>

-----------------------------------------------------------------------------
(* Hub: the NodeChannel and Photon.Machines *)

\* The channel handles one request from its mailbox. "joined" and
\* "pstart" read rows; the fixed design reads them through the Store, so
\* they wait for a commit in progress. That commit also records pushed on
\* every row it returns op.start for.
SetPushed(r) == [r EXCEPT !.psh = TRUE]

ChanCmd ==
    /\ chan = "up" /\ cq # <<>>
    /\ LET m == Head(cq)
           c == m[2]
           reads == m[1] \in {"joined", "pstart"}
       IN
       /\ reads => (~Busy \/ Bug("unserialized-read"))
       /\ cq' = Tail(cq)
       /\ CASE m[1] = "joined" ->
                 /\ h2n' = h2n \o JoinPushes
                 /\ row' = [k \in Calls |-> IF row[k].st = "open" /\ ~row[k].cx
                                            THEN SetPushed(row[k]) ELSE row[k]]
                 /\ startCx' = [k \in Calls |-> startCx[k] \/
                                  (Bug("start-after-cancel") /\ row[k].st = "open" /\ row[k].cx)]
            [] m[1] = "pstart" ->
                 /\ IF row[c].st = "open" /\ ~row[c].cx
                    THEN /\ h2n' = Append(h2n, <<"start", c, row[c].conf>>)
                         /\ row' = [row EXCEPT ![c] = SetPushed(@)]
                    ELSE UNCHANGED <<h2n, row>>
                 /\ UNCHANGED startCx
            [] m[1] = "start" ->
                 \* stale-start bug only: an op.start built elsewhere
                 /\ h2n' = Append(h2n, m)
                 /\ row' = IF row[c].st # "none" THEN [row EXCEPT ![c] = SetPushed(@)] ELSE row
                 /\ startCx' = [startCx EXCEPT ![c] = @ \/ row[c].cx]
            [] m[1] = "cancel" ->
                 /\ h2n' = Append(h2n, m)
                 /\ UNCHANGED <<row, startCx>>
    /\ UNCHANGED <<sig, tst, tph, abReq, offS, tres, nres,
                   step, skn, orph, okn, pend, ron, chan, hpend, n2h, nodeV,
                   execs, nodeCx, cxEver, runCx, everJ, exitOk, wipeConf, preWipe, budget>>

\* handle_in("op.snapshot") -> Machines.snapshot/3: one Store commit
\* applying Machines.Rules.on_snapshot (rules 3-6), then the pushes.
HubRecv ==
    /\ chan = "up" /\ n2h # <<>> /\ ~Busy /\ hpend = <<>>
    /\ n2h' = Tail(n2h)
    /\ LET c == Head(n2h)[1]
           s == Head(n2h)[2]
       IN
       CASE row[c].st = "open" /\ s \in Terminal ->
              IF Bug("ack-early")
              THEN /\ h2n' = Append(h2n, <<"ack", c, FALSE>>)
                   /\ hpend' = <<c, s>>
                   /\ UNCHANGED <<row, sig>>
              ELSE /\ Finish(c, s)
                   /\ h2n' = Append(h2n, <<"ack", c, FALSE>>)
                   /\ UNCHANGED hpend
         [] row[c].st = "open" ->
              /\ row' = [row EXCEPT ![c].conf = TRUE]
              /\ UNCHANGED <<sig, h2n, hpend>>
         [] OTHER ->
              \* finished, closed, or no row: ack a result, cancel the rest
              /\ h2n' = Append(h2n, IF s \in Terminal THEN <<"ack", c, FALSE>>
                                                      ELSE <<"cancel", c, FALSE>>)
              /\ UNCHANGED <<row, sig, hpend>>
    /\ UNCHANGED <<tst, tph, abReq, offS, tres, nres, step, skn, orph, okn, pend, ron, chan, cq,
                   nodeV, ghost, budget>>

\* ack-early bug only: the commit after the ack.
HubCommitPending ==
    /\ hpend # <<>> /\ ~Busy
    /\ hpend' = <<>>
    /\ IF row[hpend[1]].st = "open" THEN Finish(hpend[1], hpend[2]) ELSE UNCHANGED <<row, sig>>
    /\ UNCHANGED <<tst, tph, abReq, offS, tres, nres, step, skn, orph, okn, pend, ron, chan, cq,
                   wire, nodeV, ghost, budget>>

\* The channel of a dropped socket terminates and unregisters.
HubChanDown ==
    /\ chan = "stale"
    /\ chan' = "none"
    /\ UNCHANGED <<hubDb, step, skn, orph, okn, pend, ron, cq, hpend, wire, nodeV, ghost, budget>>

-----------------------------------------------------------------------------
(* The connection *)

\* The node connects and joins; NodeChannel.join/3 registers (taking over a
\* stale channel) and sends itself :joined.
Connect ==
    /\ conn = "down" /\ chan # "up"
    /\ conn' = "joining"
    /\ chan' = "up"
    /\ cq' = << <<"joined", 0, FALSE>> >>
    /\ h2n' = <<>> /\ n2h' = <<>>
    /\ UNCHANGED <<hubDb, step, skn, orph, okn, pend, ron, hpend, fq, jr, proc, pcx, cmd,
                   ghost, budget>>

\* Connection.handle_join: push every journaled snapshot (Executor.snapshots/0).
NodeJoin ==
    /\ conn = "joining"
    /\ conn' = "up"
    /\ n2h' = n2h \o JournalSnaps
    /\ UNCHANGED <<hubDb, hubMem, h2n, fq, jr, proc, pcx, cmd, ghost, budget>>

\* The Connection handles a forwarded snapshot: pushed if joined, dropped
\* if the join reply hasn't been handled yet (it sits behind this one).
NodeForward ==
    /\ fq # <<>> /\ conn \in {"joining", "up"}
    /\ fq' = Tail(fq)
    /\ n2h' = IF conn = "up" THEN Append(n2h, Head(fq)) ELSE n2h
    /\ UNCHANGED <<hubDb, hubMem, h2n, conn, jr, proc, pcx, cmd, ghost, budget>>

-----------------------------------------------------------------------------
(* Node: the executor (Connection -> Executor.start/cancel/ack) *)

RecvStart(c, k) ==
    IF jr[c].st = "none"
    THEN IF ~k \/ Bug("no-known")
         THEN \* rule 1: journal ready, then start the op process
              /\ jr' = [jr EXCEPT ![c] = [st |-> "ready", cx |-> FALSE]]
              /\ Fwd(c, "ready")
              /\ proc' = [proc EXCEPT ![c] = "ck"]
              /\ pcx' = [pcx EXCEPT ![c] = FALSE]
              /\ everJ' = [everJ EXCEPT ![c] = TRUE]
              /\ runCx' = [runCx EXCEPT ![c] = @ \/ nodeCx[c]]
              /\ UNCHANGED <<nodeCx, cxEver>>
         ELSE \* rule 3: known but no journal: the "no record" failure
              /\ Fwd(c, "lost")
              /\ UNCHANGED <<jr, proc, pcx, everJ, runCx, nodeCx, cxEver>>
    ELSE \* rule 2: send the journaled snapshot (NodeResume resumes it)
         /\ Fwd(c, jr[c].st)
         /\ UNCHANGED <<jr, proc, pcx, everJ, runCx, nodeCx, cxEver>>

RecvCancel(c) ==
    /\ nodeCx' = [nodeCx EXCEPT ![c] = TRUE]
    /\ cxEver' = [cxEver EXCEPT ![c] = TRUE]
    /\ CASE jr[c].st = "none" ->
              IF Bug("cancel-unjournaled")
              THEN /\ Fwd(c, "canceled")
                   /\ UNCHANGED <<jr, everJ>>
              ELSE \* fixed rule 7: journal "canceled before it started"
                   /\ jr' = [jr EXCEPT ![c] = [st |-> "canceled", cx |-> TRUE]]
                   /\ Fwd(c, "canceled")
                   /\ everJ' = [everJ EXCEPT ![c] = TRUE]
         [] jr[c].st \in Terminal -> UNCHANGED <<jr, fq, everJ>>
         [] OTHER ->
              /\ jr' = [jr EXCEPT ![c].cx = TRUE]
              /\ UNCHANGED <<fq, everJ>>
    /\ pcx' = IF proc[c] # "none" THEN [pcx EXCEPT ![c] = TRUE] ELSE pcx
    /\ UNCHANGED <<proc, runCx>>

\* Rule 6: forget a result once the hub has it.
RecvAck(c) ==
    /\ jr' = IF jr[c].st \in Terminal THEN [jr EXCEPT ![c] = NoJr] ELSE jr
    /\ UNCHANGED <<fq, proc, pcx, everJ, runCx, nodeCx, cxEver>>

NodeRecv ==
    /\ conn = "up" /\ h2n # <<>>
    /\ h2n' = Tail(h2n)
    /\ LET m == Head(h2n) IN
       CASE m[1] = "start"  -> RecvStart(m[2], m[3])
         [] m[1] = "cancel" -> RecvCancel(m[2])
         [] m[1] = "ack"    -> RecvAck(m[2])
    /\ UNCHANGED <<hubDb, hubMem, n2h, conn, cmd,
                   execs, startCx, exitOk, wipeConf, preWipe, budget>>

-----------------------------------------------------------------------------
(* Node: op processes and commands (Ops.Shell, with the executor as owner) *)

\* The process checkpoint (rule 4): the executor journals it unless the
\* journal says canceled.
OpCheckpoint(c) ==
    /\ proc[c] = "ck"
    /\ IF jr[c].cx
       THEN /\ jr' = [jr EXCEPT ![c].st = "canceled"]
            /\ Fwd(c, "canceled")
            /\ proc' = [proc EXCEPT ![c] = "none"]
            /\ UNCHANGED <<cmd, execs>>
       ELSE IF Bug("spawn-before-journal")
       THEN /\ proc' = [proc EXCEPT ![c] = "jw"]
            /\ Spawn(c)
            /\ UNCHANGED <<jr, fq>>
       ELSE /\ jr' = [jr EXCEPT ![c].st = "proc"]
            /\ Fwd(c, "proc")
            /\ proc' = [proc EXCEPT ![c] = "go"]
            /\ UNCHANGED <<cmd, execs>>
    /\ UNCHANGED <<hubDb, hubMem, wire, conn, pcx,
                   nodeCx, cxEver, runCx, startCx, everJ, exitOk, wipeConf, preWipe, budget>>

\* spawn-before-journal bug only: the checkpoint written after the spawn.
OpJournal(c) ==
    /\ proc[c] = "jw"
    /\ jr' = [jr EXCEPT ![c].st = "proc"]
    /\ Fwd(c, "proc")
    /\ proc' = [proc EXCEPT ![c] = "wait"]
    /\ UNCHANGED <<hubDb, hubMem, wire, conn, pcx, cmd, ghost, budget>>

OpSpawn(c) ==
    /\ proc[c] = "go"
    /\ proc' = [proc EXCEPT ![c] = "wait"]
    /\ Spawn(c)
    /\ UNCHANGED <<hubDb, hubMem, wire, conn, fq, jr, pcx,
                   nodeCx, cxEver, runCx, startCx, everJ, exitOk, wipeConf, preWipe, budget>>

\* A canceled op kills its command's process group.
OpKill(c) ==
    /\ proc[c] \in {"wait", "jw"} /\ pcx[c] /\ cmd[c] = "running"
    /\ cmd' = [cmd EXCEPT ![c] = "killed"]
    /\ UNCHANGED <<hubDb, hubMem, wire, conn, fq, jr, proc, pcx, ghost, budget>>

CmdExit(c) ==
    /\ cmd[c] = "running"
    /\ cmd' = [cmd EXCEPT ![c] = "exited"]
    /\ exitOk' = [exitOk EXCEPT ![c] = TRUE]
    /\ UNCHANGED <<hubDb, hubMem, wire, conn, fq, jr, proc, pcx,
                   execs, nodeCx, cxEver, runCx, startCx, everJ, wipeConf, preWipe, budget>>

\* The op process sees the command end and reports its terminal snapshot.
OpFinish(c) ==
    /\ proc[c] = "wait" /\ cmd[c] \in {"exited", "killed"}
    /\ LET s == IF cmd[c] = "exited" THEN "completed" ELSE "canceled" IN
       /\ jr' = [jr EXCEPT ![c].st = s]
       /\ Fwd(c, s)
    /\ proc' = [proc EXCEPT ![c] = "none"]
    /\ pcx' = [pcx EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<hubDb, hubMem, wire, conn, cmd, ghost, budget>>

\* The executor resumes an unfinished journaled op with no process (its
\* start-up scan, a restart after a clean exit, or rule 2), and tells the
\* resumed process to cancel if the journal says so (node rule 2).
\* Ops.Shell's recovery: reattach to a running command, finish from the
\* exit file, fail when the outcome is unknown or the node stopped it.
NodeResume(c) ==
    /\ proc[c] = "none" /\ jr[c].st \in {"ready", "proc"}
    /\ IF jr[c].st = "ready"
       THEN /\ proc' = [proc EXCEPT ![c] = "ck"]
            /\ pcx' = [pcx EXCEPT ![c] = jr[c].cx]
            /\ UNCHANGED <<jr, fq>>
       ELSE CASE cmd[c] = "running" ->
                   /\ proc' = [proc EXCEPT ![c] = "wait"]
                   /\ pcx' = [pcx EXCEPT ![c] = jr[c].cx]
                   /\ UNCHANGED <<jr, fq>>
              [] cmd[c] = "exited" ->
                   /\ jr' = [jr EXCEPT ![c].st = "completed"] /\ Fwd(c, "completed")
                   /\ UNCHANGED <<proc, pcx>>
              [] cmd[c] = "killed" ->
                   /\ jr' = [jr EXCEPT ![c].st = "canceled"] /\ Fwd(c, "canceled")
                   /\ UNCHANGED <<proc, pcx>>
              [] OTHER ->
                   /\ jr' = [jr EXCEPT ![c].st = "failed"] /\ Fwd(c, "failed")
                   /\ UNCHANGED <<proc, pcx>>
    /\ UNCHANGED <<hubDb, hubMem, wire, conn, cmd, ghost, budget>>

-----------------------------------------------------------------------------
(* Faults *)

\* The websocket drops: pushes in flight both ways are lost, the channel
\* lingers (stale) and its mailbox goes nowhere.
Disconnect ==
    /\ conn # "down" /\ nDisc < MaxDisconnects
    /\ nDisc' = nDisc + 1
    /\ conn' = "down" /\ fq' = <<>>
    /\ h2n' = <<>> /\ n2h' = <<>>
    /\ chan' = IF chan = "up" THEN "stale" ELSE chan
    /\ cq' = <<>>
    /\ UNCHANGED <<hubDb, step, skn, orph, okn, pend, ron, hpend, jr, proc, pcx, cmd, ghost,
                   nHub, nSched, nNode, nWipe, nStop, nErr, nRep>>

\* The hub VM restarts: SQLite survives; steps, channels, a commit in
\* progress (rolled back) and the registry don't. Running tasks go back
\* to pending (Scheduler.init).
HubCrash ==
    /\ nHub < MaxHubCrashes
    /\ nHub' = nHub + 1
    /\ tst' = [c \in Calls |-> IF tst[c] = "running" THEN "pending" ELSE tst[c]]
    /\ step' = [c \in Calls |-> "none"]
    /\ orph' = [c \in Calls |-> "none"]
    /\ pend' = [c \in Calls |-> "-"]
    /\ ron' = [c \in Calls |-> FALSE]
    /\ chan' = "none" /\ cq' = <<>> /\ hpend' = <<>>
    /\ h2n' = <<>> /\ n2h' = <<>>
    /\ conn' = "down" /\ fq' = <<>>
    /\ UNCHANGED <<row, sig, tph, abReq, offS, tres, nres, skn, okn,
                   jr, proc, pcx, cmd, ghost, nDisc, nSched, nNode, nWipe, nStop, nErr, nRep>>

\* Only the Scheduler dies; its steps keep running (Task.Supervisor) and
\* their tasks go back to pending. A step still before its Machines.start
\* commit or send becomes an orphan.
SchedCrash ==
    /\ nSched < MaxSchedCrashes /\ ~Busy
    /\ nSched' = nSched + 1
    /\ tst' = [c \in Calls |-> IF tst[c] = "running" THEN "pending" ELSE tst[c]]
    /\ orph' = [c \in Calls |-> IF step[c] \in {"ins", "send"} THEN step[c] ELSE orph[c]]
    /\ okn' = skn
    /\ step' = [c \in Calls |-> "none"]
    /\ UNCHANGED <<row, sig, tph, abReq, offS, tres, nres, skn, pend, ron, chan, cq, hpend,
                   wire, nodeV, ghost, nDisc, nHub, nNode, nWipe, nStop, nErr, nRep>>

\* The node VM restarts: the journal survives, op processes don't. A
\* running command may survive (abrupt crash) or be killed on the way down.
NodeRestart ==
    /\ nNode < MaxNodeRestarts
    /\ nNode' = nNode + 1
    /\ \E keep \in SUBSET {c \in Calls : cmd[c] = "running"} :
         cmd' = [c \in Calls |-> IF cmd[c] = "running" /\ c \notin keep THEN "lost" ELSE cmd[c]]
    /\ proc' = [c \in Calls |-> "none"]
    /\ pcx' = [c \in Calls |-> FALSE]
    /\ conn' = "down" /\ fq' = <<>>
    /\ h2n' = <<>> /\ n2h' = <<>>
    /\ chan' = IF chan = "up" THEN "stale" ELSE chan
    /\ cq' = <<>>
    /\ UNCHANGED <<hubDb, step, skn, orph, okn, pend, ron, hpend, jr, ghost,
                   nDisc, nHub, nSched, nWipe, nStop, nErr, nRep>>

\* The node's data directory is lost (reinstalled): journal gone, commands
\* gone. Not a fault the protocol hides; the "known" flag limits it.
NodeWipe ==
    /\ nWipe < MaxWipes
    /\ nWipe' = nWipe + 1
    /\ cmd' = [c \in Calls |-> IF cmd[c] = "running" THEN "lost" ELSE cmd[c]]
    /\ jr' = [c \in Calls |-> NoJr]
    /\ proc' = [c \in Calls |-> "none"]
    /\ pcx' = [c \in Calls |-> FALSE]
    /\ conn' = "down" /\ fq' = <<>>
    /\ h2n' = <<>> /\ n2h' = <<>>
    /\ chan' = IF chan = "up" THEN "stale" ELSE chan
    /\ cq' = <<>>
    /\ nodeCx' = [c \in Calls |-> FALSE]
    /\ wipeConf' = [c \in Calls |-> wipeConf[c] \/ row[c].conf]
    /\ preWipe' = execs
    /\ UNCHANGED <<hubDb, step, skn, orph, okn, pend, ron, hpend,
                   execs, cxEver, runCx, startCx, everJ, exitOk,
                   nDisc, nHub, nSched, nNode, nStop, nErr, nRep>>

-----------------------------------------------------------------------------
Next ==
    \/ \E c \in Calls :
         \/ CallStart(c) \/ SchedStart(c) \/ ExecIns(c) \/ ExecSend(c) \/ ExecPark(c)
         \/ Wake(c) \/ ResumeRead(c) \/ ResumeCommit(c) \/ UserStop(c)
         \/ SchedAbort1(c) \/ CommitEnd(c) \/ StepError(c)
         \/ OrphIns(c) \/ OrphSend(c)
         \/ OpCheckpoint(c) \/ OpJournal(c) \/ OpSpawn(c) \/ OpKill(c) \/ CmdExit(c)
         \/ OpFinish(c) \/ NodeResume(c)
    \/ ChanCmd \/ HubRecv \/ HubCommitPending \/ HubChanDown
    \/ Connect \/ NodeJoin \/ NodeForward \/ NodeRecv
    \/ Disconnect \/ HubCrash \/ SchedCrash \/ NodeRestart \/ NodeWipe

\* Every process takes its steps, the node keeps reconnecting, a parked
\* call keeps being checked. Calls, Stops, errors and faults get no fairness;
\* faults are bounded, so every behavior ends with the node reachable.
\* Commands exit on their own only when CmdsEnd.
Fairness ==
    /\ \A c \in Calls :
         /\ WF_vars(SchedStart(c)) /\ WF_vars(ExecIns(c)) /\ WF_vars(ExecSend(c))
         /\ WF_vars(ExecPark(c)) /\ WF_vars(Wake(c))
         /\ WF_vars(ResumeRead(c)) /\ WF_vars(ResumeCommit(c))
         /\ WF_vars(SchedAbort1(c)) /\ WF_vars(CommitEnd(c))
         /\ WF_vars(OrphIns(c)) /\ WF_vars(OrphSend(c))
         /\ WF_vars(OpCheckpoint(c)) /\ WF_vars(OpJournal(c)) /\ WF_vars(OpSpawn(c))
         /\ WF_vars(OpKill(c)) /\ WF_vars(OpFinish(c)) /\ WF_vars(NodeResume(c))
         /\ (CmdsEnd => WF_vars(CmdExit(c)))
    /\ WF_vars(ChanCmd) /\ WF_vars(HubRecv) /\ WF_vars(HubCommitPending)
    /\ WF_vars(HubChanDown)
    /\ WF_vars(Connect) /\ WF_vars(NodeJoin) /\ WF_vars(NodeForward) /\ WF_vars(NodeRecv)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* Safety *)

TypeOK ==
    /\ \A c \in Calls :
         /\ row[c].st \in {"none", "open", "finished", "closed"}
         /\ row[c].snap \in Terminal \cup {"-"}
         /\ tst[c] \in {"none", "pending", "running", "waiting", "done"}
         /\ tres[c] \in Results \cup {"-"}
         /\ step[c] \in {"none", "ins", "send", "park", "res", "rc"}
         /\ pend[c] \in {"-", "stopped", "error", "offline-norun", "offline-maybe"}
         /\ orph[c] \in {"none", "ins", "send"}
         /\ jr[c].st \in {"none", "ready", "proc", "completed", "failed", "canceled"}
         /\ proc[c] \in {"none", "ck", "go", "jw", "wait"}
         /\ cmd[c] \in {"none", "running", "exited", "killed", "lost"}
    /\ chan \in {"none", "up", "stale"}
    /\ conn \in {"down", "joining", "up"}
    /\ chan = "up" \/ cq = <<>>

\* A command runs at most once per tool call (no data loss on the node).
AtMostOnceSpawn == \A c \in Calls : execs[c] <= 1

\* With data loss: an op the hub knew the node had is never run again.
KnownNotRerun == \A c \in Calls : wipeConf[c] => execs[c] = preWipe[c]

\* Each call gets one result, recorded once.
OneResult ==
    \A c \in Calls : nres[c] <= 1 /\ ((tst[c] = "done") <=> (nres[c] = 1))

\* A call's result is the outcome of its own op as the node saw it: a
\* "completed" op's command ran and exited; "canceled" only after the node
\* handled op.cancel for it; "failed" only after a node restart or data
\* loss; "no record" only after data loss; an error only after a step
\* failed; never the closed-row guard.
ResultFromOwnOp ==
    \A c \in Calls :
        /\ tres[c] = "completed" => exitOk[c]
        /\ tres[c] = "canceled" => cxEver[c]
        /\ tres[c] = "failed" => nNode + nWipe > 0
        /\ tres[c] = "lost" => nWipe > 0
        /\ tres[c] = "error" => nErr > 0
        /\ tres[c] # "guard"

\* The offline result says "the command didn't run" only if it never ran,
\* and never will (data loss included: nothing was ever pushed).
OfflineNotRun == \A c \in Calls : tres[c] = "offline-norun" => execs[c] = 0

\* The hub never pushes op.start for a row with cancel set.
NoStartAfterCancel == \A c \in Calls : ~startCx[c]

\* The node never starts an op it has handled op.cancel for.
NoRunAfterCancel == \A c \in Calls : ~runCx[c]

\* The node forgets an op only after the hub recorded its result.
JournalUntilRecorded ==
    \A c \in Calls : (everJ[c] /\ jr[c].st = "none") => row[c].st \in {"finished", "closed"}

\* A finished call leaves no op that may still start: its row is closed,
\* finished, or open with cancel set.
NoLiveRowAfterDone ==
    \A c \in Calls : (tst[c] = "done" /\ row[c].st = "open") => row[c].cx

\* A row closes only once its call has its result.
ClosedOnlyWhenDone ==
    \A c \in Calls : row[c].st = "closed" => tst[c] = "done"

\* The signal fires only with the result recorded.
SignalMeansRecorded ==
    \A c \in Calls : sig[c] => row[c].st \in {"finished", "closed"}

-----------------------------------------------------------------------------
(* Liveness (bounded faults: the node ends up reachable) *)

\* Every call eventually gets its result (needs CmdsEnd).
CallAnswered == \A c \in Calls : (tst[c] # "none") ~> (tst[c] = "done")

\* A cancel eventually takes effect: the row closes and the command isn't
\* running. Meaningful with CmdsEnd = FALSE, where only a kill ends it.
CancelTakesEffect ==
    \A c \in Calls : row[c].cx ~> (row[c].st = "closed" /\ cmd[c] # "running")

\* A result on the node is dropped once the hub has it.
ResultsDropped ==
    \A c \in Calls : (jr[c].st \in Terminal) ~> (jr[c].st = "none")

\* Every op row ends closed, so no finished snapshot is kept for good
\* (needs CmdsEnd).
RowsClose == \A c \in Calls : (row[c].st # "none") ~> (row[c].st = "closed")

=============================================================================
