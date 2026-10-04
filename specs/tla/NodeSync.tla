------------------------------ MODULE NodeSync ------------------------------
(***************************************************************************)
(* Hub <-> node session replication and the hub's input outbox, as the    *)
(* code implements them after the verification fixes. NodeSync.md maps     *)
(* every action to the code and lists the fixes and the findings behind    *)
(* them.                                                                   *)
(*                                                                         *)
(* One session. The protocol is per session; sessions only share the       *)
(* websocket, the Connection process and the join reply, and none of the   *)
(* properties relate two sessions. A finite set of hub inputs, numbered in *)
(* the order the hub inserts them.                                         *)
(*                                                                         *)
(* Node side                                                               *)
(*   log      the session's append-only JSONL log (Store); index = offset  *)
(*   Connection (Slipstream client): conn, sent, nq, dlv                   *)
(*   Coordinator: alive, cpc, mbox, seen, busy, llm, undel, callModel,     *)
(*                stopReq, lastAns                                         *)
(*   stopAsk: observation, a hub stop the node took while the session was  *)
(*            working, until its hard stop input is in the log             *)
(* Wire (one websocket; Phoenix channels are FIFO per connection)          *)
(*   h2n hub -> node pushes, n2h node -> hub pushes, reply = join reply    *)
(* Hub side                                                                *)
(*   SQLite: hubSession, hubLog (node_events + next_offset), inState,      *)
(*           inAns (node_inputs)                                           *)
(*   memory: chan (NodeChannel/NodeRegistry), pushed (inputs the current   *)
(*           channel has pushed)                                           *)
(*   sigCount: how many times the node_input:<id> signal was recorded      *)
(*                                                                         *)
(* Offsets are 0-based like the code: the record at offset k is log[k+1].  *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS
    Inputs,           \* hub input ids, a set of naturals in insertion order
    MaxDisconnects,   \* websocket drops / channel or Connection crashes
    MaxNodeRestarts,  \* node VM restarts
    MaxHubRestarts,   \* hub VM restarts
    MaxCoordCrashes,  \* coordinator crashes (DynamicSupervisor restarts it)
    MaxRejects,       \* deliveries refused because the session can't be created
    MaxStops,         \* "stop" commands sent by the hub
    MaxRepush,        \* extra sends of an existing input id (see HubRepush)
    IdleStopRace      \* coordinator may idle-stop while inputs reach its mailbox

VARIABLES
    log,
    conn, sent, nq, dlv,
    alive, cpc, mbox, seen, busy, llm, undel, callModel, stopReq, lastAns,
    stopAsk,
    h2n, n2h, reply,
    hubSession, hubLog, inState, inAns,
    chan, pushed,
    sigCount,
    nDisc, nNodeRst, nHubRst, nCrash, nRej, nStop, nRepush

connV   == <<conn, sent, nq, dlv>>
coordV  == <<alive, cpc, mbox, seen, busy, llm, undel, callModel, stopReq, lastAns,
             stopAsk>>
wireV   == <<h2n, n2h, reply>>
hubDbV  == <<hubSession, hubLog, inState, inAns>>
hubMemV == <<chan, pushed>>
budgetV == <<nDisc, nNodeRst, nHubRst, nCrash, nRej, nStop, nRepush>>
vars    == <<log, connV, coordV, wireV, hubDbV, hubMemV, sigCount, budgetV>>

-----------------------------------------------------------------------------
(* Helpers *)

Max(S) == CHOOSE x \in S : \A y \in S : x >= y
Max2(a, b) == IF a >= b THEN a ELSE b
Range(s) == {s[k] : k \in DOMAIN s}
Bump(n) == IF n < 2 THEN n + 1 ELSE 2

(* Log records (Store moduledoc), reduced to what matters:
     <<"hdr", 0>>       session header, always offset 0
     <<"in", i>>        an external input with hub id i
     <<"ctl", 0>>       a control input with a fresh node-made id (hard stop)
     <<"run", 0>>       state: running
     <<"resp", t>>      model_response; t = 1 if its message has text, 0 if
                        the text is empty or the request failed (message nil)
     <<"idle", a>>      state: idle, answer = text of the resp at offset a
                        (a = -1: answer nil)
     <<"stopped", 0>>   state: stopped (no answer field)
   turn, tool_call_status and operation records are left out: the hub
   ignores them and they don't change when a run starts or ends. *)

IdxOf(l, kinds) == {k \in 1..Len(l) : l[k][1] \in kinds}
LastIdx(l, kinds) == IF IdxOf(l, kinds) = {} THEN 0 ELSE Max(IdxOf(l, kinds))
InLog(i) == \E k \in 1..Len(log) : log[k] = <<"in", i>>

\* Harness.working?/1: the last state record is "running" ...
Running(l) ==
    LET k == LastIdx(l, {"run", "idle", "stopped"}) IN k > 0 /\ l[k][1] = "run"

\* ... or an external input follows the last model response or stop
\* (pending(state) > 0 after replaying l: available vs delivered).
Undelivered(l) == LastIdx(l, {"in"}) > LastIdx(l, {"resp", "stopped"})

Working(l) == Running(l) \/ Undelivered(l)

\* A hard stop with no "stopped" after it: re-armed on replay
\* (apply_input/2 for a hard control input; "stopped" clears it).
StopPending(l) == LastIdx(l, {"ctl"}) > LastIdx(l, {"stopped"})

\* state.last_answer after replaying l: the latest non-empty model text
\* since the last external input (apply_input/2 clears it).
LastAns(l) ==
    LET T == {k \in 1..Len(l) : l[k] = <<"resp", 1>>} IN
    IF T = {} \/ Max(T) < LastIdx(l, {"in"}) THEN -1 ELSE Max(T) - 1

Seen(l) == {i \in Inputs : \E k \in 1..Len(l) : l[k] = <<"in", i>>}

\* Store.append + Connection.event (the {:persist, ...} effect that
\* Coordinator runs for Session.record/3). The new
\* record's offset is Len(log). A notification handled while the
\* Connection isn't joined is dropped, and whatever sits in its mailbox
\* when a connection drops is handled before the next join reply arrives,
\* so it is dropped too. We drop both right away: nq only holds
\* notifications that will be handled while joined.
AppendNotify(rec) ==
    /\ log' = Append(log, rec)
    /\ nq' = IF conn = "up" THEN Append(nq, Len(log)) ELSE nq

\* Coordinator.init + handle_continue(:start): rebuild from the log; the
\* mailbox becomes m.
CoordReset(l, m) ==
    /\ alive' = TRUE
    /\ cpc' = "start"
    /\ mbox' = m
    /\ seen' = Seen(l)             \* Inbox.new(input_ids)
    /\ busy' = Running(l)          \* apply_item "state"
    /\ llm' = FALSE                \* the linked model task died with the old one
    /\ undel' = Undelivered(l)
    /\ callModel' = Undelivered(l)
    /\ stopReq' = StopPending(l)
    /\ lastAns' = LastAns(l)

CoordDown ==
    /\ alive' = FALSE /\ cpc' = "wait" /\ mbox' = <<>> /\ seen' = {}
    /\ busy' = FALSE /\ llm' = FALSE /\ undel' = FALSE /\ callModel' = FALSE
    /\ stopReq' = FALSE /\ lastAns' = -1

\* Harness.deliver is a call that returns once the input is persisted. If
\* the coordinator dies first (crash, idle stop), its mailbox is lost and
\* the call exits; deliver retries with the coordinator's successor. So a
\* delivery in progress (dlv) survives in the successor's mailbox.
\* Harness.stop delivers its hard stop the same way (dlv = -1).
Retry == CASE dlv > 0  -> << <<"input", dlv>> >>
           [] dlv = -1 -> << <<"stop", 0>> >>
           [] OTHER    -> <<>>

\* replay/3: one read of the log; the watermark is `from` plus the records
\* pushed.
Replay(from) ==
    IF from < Len(log) THEN
        /\ n2h' = n2h \o [k \in 1..(Len(log) - from) |->
                            <<"ev", from + k - 1, log[from + k]>>]
        /\ sent' = Len(log)
    ELSE
        /\ sent' = from
        /\ UNCHANGED n2h

\* resend_queued/1: queued inputs, oldest first.
QueuedSet == {i \in Inputs : inState[i] = "queued"}
QueuedSeq ==
    LET Q == QueuedSet
        nth(k) == CHOOSE i \in Q : Cardinality({j \in Q : j < i}) = k - 1
    IN [k \in 1..Cardinality(Q) |-> <<"input", nth(k)>>]

\* Nodes.command/3 + NodeChannel handle_info({:command}): pushed if the
\* node's channel is registered. A registered channel whose socket is
\* already gone ("stale") loses it. A channel pushes an input id at most
\* once (pushed).
Command(m) ==
    /\ h2n' = IF chan = "up" /\ ~(m[1] = "input" /\ m[2] \in pushed)
              THEN Append(h2n, m) ELSE h2n
    /\ pushed' = IF chan = "up" /\ m[1] = "input" THEN pushed \cup {m[2]} ELSE pushed

\* The node_input:<id> signal for inputs in S, recorded in the same commit
\* as the settle or reject (NodeSessions.ingest/reject_input through
\* Durable.Store with Tx.signal).
Fire(S) == sigCount' = [i \in Inputs |-> IF i \in S THEN Bump(sigCount[i]) ELSE sigCount[i]]

-----------------------------------------------------------------------------
Init ==
    /\ log = <<>>
    /\ conn = "down" /\ sent = -1 /\ nq = <<>> /\ dlv = 0
    /\ alive = FALSE /\ cpc = "wait" /\ mbox = <<>> /\ seen = {}
    /\ busy = FALSE /\ llm = FALSE /\ undel = FALSE /\ callModel = FALSE
    /\ stopReq = FALSE /\ lastAns = -1
    /\ stopAsk = FALSE
    /\ h2n = <<>> /\ n2h = <<>> /\ reply = -1
    /\ hubSession = FALSE /\ hubLog = <<>>
    /\ inState = [i \in Inputs |-> "none"]
    /\ inAns = [i \in Inputs |-> -3]
    /\ chan = "none" /\ pushed = {}
    /\ sigCount = [i \in Inputs |-> 0]
    /\ nDisc = 0 /\ nNodeRst = 0 /\ nHubRst = 0 /\ nCrash = 0
    /\ nRej = 0 /\ nStop = 0 /\ nRepush = 0

-----------------------------------------------------------------------------
(* Node: the session coordinator *)

\* handle_call({:deliver, ...}) / handle_info({:input, _}) and the drain in
\* slurp/1 -> handle_input/3. Inbox.accept drops an id it has seen; a new
\* input is persisted, then applied, and the delivery call is answered.
\* External input that arrives while a hard stop is pending is held until
\* "stopped" is written (it waits here; CoordDecide writes "stopped").
CoordInput ==
    /\ alive /\ cpc \in {"wait", "drain"} /\ mbox # <<>>
    /\ ~(Head(mbox)[1] = "input" /\ stopReq /\ Head(mbox)[2] \notin seen)
    /\ mbox' = Tail(mbox)
    /\ LET m == Head(mbox) IN
       IF m[1] = "stop" THEN
            \* Harness.stop's hard control input with a fresh id; accept_stop
            /\ AppendNotify(<<"ctl", 0>>)
            /\ stopReq' = TRUE /\ cpc' = "drain"
            /\ dlv' = IF dlv = -1 THEN 0 ELSE dlv
            /\ stopAsk' = FALSE
            /\ UNCHANGED <<seen, undel, callModel, lastAns>>
       ELSE IF m[2] \in seen THEN
            /\ dlv' = IF dlv = m[2] THEN 0 ELSE dlv
            /\ UNCHANGED <<log, nq, cpc, seen, undel, callModel, stopReq, lastAns, stopAsk>>
       ELSE
            /\ AppendNotify(<<"in", m[2]>>)
            /\ seen' = seen \cup {m[2]}
            /\ undel' = TRUE /\ callModel' = TRUE /\ cpc' = "drain"
            /\ lastAns' = -1
            /\ dlv' = IF dlv = m[2] THEN 0 ELSE dlv
            /\ UNCHANGED <<stopReq, stopAsk>>
    /\ UNCHANGED <<alive, busy, llm, conn, sent, wireV, hubDbV, hubMemV,
                   sigCount, budgetV>>

\* decide/1: handle_stop, else request_model_response when call_model or
\* something is pending and no request runs, then record_run_state. Each
\* callback that changed state ends here; "start" is
\* handle_continue(:start).
CoordDecide ==
    /\ alive /\ cpc \in {"start", "drain"}
    /\ cpc' = "wait"
    /\ IF stopReq THEN
            \* no operations in this model, so "stopped" is written at once
            /\ AppendNotify(<<"stopped", 0>>)
            /\ llm' = FALSE /\ callModel' = FALSE /\ undel' = FALSE
            /\ stopReq' = FALSE /\ busy' = FALSE
       ELSE IF callModel \/ (undel /\ ~llm) THEN
            \* a new turn (cancelling any request in flight), then "running"
            /\ llm' = TRUE /\ callModel' = FALSE
            /\ IF busy THEN UNCHANGED <<log, nq, busy>>
               ELSE AppendNotify(<<"run", 0>>) /\ busy' = TRUE
            /\ UNCHANGED <<undel, stopReq>>
       ELSE
            /\ IF busy /\ ~llm /\ ~undel
                 THEN AppendNotify(<<"idle", lastAns>>) /\ busy' = FALSE
               ELSE IF ~busy /\ (llm \/ undel)
                 THEN AppendNotify(<<"run", 0>>) /\ busy' = TRUE
               ELSE UNCHANGED <<log, nq, busy>>
            /\ UNCHANGED <<llm, callModel, undel, stopReq>>
    /\ UNCHANGED <<alive, mbox, seen, lastAns, stopAsk, conn, sent, dlv, wireV, hubDbV,
                   hubMemV, sigCount, budgetV>>

\* The model request finishes: handle_info({ref, result}) or its :DOWN ->
\* process_model_response, then slurp and decide. Model calls retry and
\* finally fail with message nil, so a response always comes. t = 0: empty
\* text or failure.
CoordResponse ==
    /\ alive /\ cpc = "wait" /\ llm
    /\ \E t \in {0, 1} :
          /\ AppendNotify(<<"resp", t>>)
          /\ lastAns' = IF t = 1 THEN Len(log) ELSE lastAns
    /\ llm' = FALSE /\ undel' = FALSE /\ cpc' = "drain"
    /\ UNCHANGED <<alive, mbox, seen, busy, callModel, stopReq, stopAsk, conn, sent,
                   dlv, wireV, hubDbV, hubMemV, sigCount, budgetV>>

\* The 10-minute :idle_stop timer fires (arm_idle_stop). It is re-armed by
\* every decide, so it can only fire while the coordinator sits idle with
\* nothing in its mailbox. cpc = "stopping": the :idle_stop message is now
\* at the head of the mailbox, ahead of anything that arrives later.
CoordIdleTimer ==
    /\ IdleStopRace
    /\ alive /\ cpc = "wait" /\ ~llm /\ ~undel /\ mbox = <<>>
    /\ cpc' = "stopping"
    /\ UNCHANGED <<log, connV, alive, mbox, seen, busy, llm, undel, callModel,
                   stopReq, lastAns, stopAsk, wireV, hubDbV, hubMemV, sigCount, budgetV>>

\* handle_info(:idle_stop): exit :normal; restart: :transient, so it stays
\* down. A delivery that reached the mailbox behind :idle_stop gets an exit
\* and is retried with a new coordinator (Harness.deliver).
CoordIdleStop ==
    /\ alive
    /\ \/ cpc = "stopping"
       \/ ~IdleStopRace /\ cpc = "wait" /\ ~llm /\ ~undel /\ mbox = <<>>
    /\ IF dlv # 0 THEN CoordReset(log, Retry) ELSE CoordDown
    /\ UNCHANGED <<log, connV, stopAsk, wireV, hubDbV, hubMemV, sigCount, budgetV>>

\* Fault: the coordinator crashes; the DynamicSupervisor restarts it
\* (restart: :transient) and it rebuilds from the log. Its mailbox is lost,
\* except the delivery in progress, which Harness.deliver retries.
CoordCrash ==
    /\ alive /\ nCrash < MaxCoordCrashes
    /\ nCrash' = nCrash + 1
    /\ CoordReset(log, Retry)
    /\ UNCHANGED <<log, connV, stopAsk, wireV, hubDbV, hubMemV, sigCount,
                   nDisc, nNodeRst, nHubRst, nRej, nStop, nRepush>>

-----------------------------------------------------------------------------
(* Node: PhotonNode.Connection *)

\* Slipstream connects and joins; the hub's NodeChannel.join replaces any
\* registered channel, registers, computes sync_for and replies; then
\* handle_info(:joined) resends queued inputs. Nothing the node sends
\* before it handles the reply exists (it only pushes while joined). The
\* Connection is busy while a delivery call is in progress (dlv).
NodeConnect ==
    /\ conn = "down" /\ dlv = 0
    /\ conn' = "joining"
    /\ chan' = "up"
    /\ pushed' = QueuedSet
    /\ reply' = IF hubSession THEN Len(hubLog) ELSE -1
    /\ h2n' = QueuedSeq
    /\ n2h' = <<>>
    /\ UNCHANGED <<log, sent, nq, dlv, coordV, hubDbV, sigCount, budgetV>>

\* handle_join: sent := %{}, then replay every session in the sync map from
\* the hub's offset.
NodeHandleJoin ==
    /\ conn = "joining" /\ dlv = 0
    /\ conn' = "up"
    /\ reply' = -1
    /\ IF reply = -1
         THEN /\ sent' = -1
              /\ UNCHANGED n2h
         ELSE Replay(reply)
    /\ UNCHANGED <<log, nq, dlv, coordV, h2n, hubDbV, hubMemV, sigCount, budgetV>>

\* handle_info({:event, id, offset, event}). A session missing from `sent`
\* starts at the notified offset.
NodeNotify ==
    /\ conn = "up" /\ dlv = 0 /\ nq # <<>>
    /\ nq' = Tail(nq)
    /\ LET off == Head(nq)
           w   == IF sent = -1 THEN off ELSE sent
       IN  IF off < w THEN UNCHANGED <<n2h, sent>>
           ELSE IF off = w THEN /\ n2h' = Append(n2h, <<"ev", off, log[off + 1]>>)
                                /\ sent' = off + 1
           ELSE Replay(sent)
    /\ UNCHANGED <<log, conn, dlv, coordV, h2n, reply, hubDbV, hubMemV, sigCount, budgetV>>

\* handle_message "input" -> Harness.deliver: ensure_session creates the log
\* with its header and notifies offset 0, ensure_started starts the
\* coordinator, then the {:deliver, config, input} call goes to it and the
\* Connection waits (dlv) until the input is persisted. The settings part
\* of the call is only recorded when the hub's config differs from the
\* log's, which it never does here (the hub's session config is fixed at
\* start/3 and is what created the log), so it is left out.
NodeRecvInput ==
    /\ conn = "up" /\ dlv = 0 /\ h2n # <<>> /\ Head(h2n)[1] = "input"
    /\ h2n' = Tail(h2n)
    /\ LET i == Head(h2n)[2] IN
       \/ \* creating the session fails (check_workspace): input_rejected
          /\ log = <<>> /\ nRej < MaxRejects
          /\ nRej' = nRej + 1
          /\ n2h' = Append(n2h, <<"rej", i, 0>>)
          /\ UNCHANGED <<log, nq, dlv, coordV>>
       \/ /\ LET l1 == IF log = <<>> THEN << <<"hdr", 0>> >> ELSE log IN
             /\ log' = l1
             /\ nq' = IF log = <<>> THEN Append(nq, 0) ELSE nq
             /\ dlv' = i
             /\ IF alive
                  THEN /\ mbox' = Append(mbox, <<"input", i>>)
                       /\ UNCHANGED <<alive, cpc, seen, busy, llm, undel,
                                      callModel, stopReq, lastAns>>
                  ELSE CoordReset(l1, << <<"input", i>> >>)
          /\ UNCHANGED <<n2h, nRej>>
    /\ UNCHANGED <<conn, sent, reply, stopAsk, hubDbV, hubMemV, sigCount,
                   nDisc, nNodeRst, nHubRst, nCrash, nStop, nRepush>>

\* handle_message "resync"
NodeRecvResync ==
    /\ conn = "up" /\ dlv = 0 /\ h2n # <<>> /\ Head(h2n)[1] = "resync"
    /\ h2n' = Tail(h2n)
    /\ Replay(Head(h2n)[2])
    /\ UNCHANGED <<log, conn, nq, dlv, coordV, reply, hubDbV, hubMemV, sigCount, budgetV>>

\* handle_message "stop" -> Harness.stop: the hard stop input goes through
\* the same delivery call as an input (dlv = -1 while it is in progress),
\* to the running coordinator, or to one started for a session whose log
\* says it is working (Harness.working?/1); otherwise there is nothing to
\* stop and it is dropped.
NodeRecvStop ==
    /\ conn = "up" /\ dlv = 0 /\ h2n # <<>> /\ Head(h2n)[1] = "stop"
    /\ h2n' = Tail(h2n)
    /\ stopAsk' = (stopAsk \/ busy \/ Working(log))
    /\ IF alive THEN
            /\ mbox' = Append(mbox, <<"stop", 0>>) /\ dlv' = -1
            /\ UNCHANGED <<alive, cpc, seen, busy, llm, undel, callModel, stopReq, lastAns>>
       ELSE IF Working(log) THEN
            /\ CoordReset(log, << <<"stop", 0>> >>) /\ dlv' = -1
       ELSE UNCHANGED <<dlv, alive, cpc, mbox, seen, busy, llm, undel, callModel,
                        stopReq, lastAns>>
    /\ UNCHANGED <<log, conn, sent, nq, n2h, reply, hubDbV, hubMemV, sigCount, budgetV>>

-----------------------------------------------------------------------------
(* Hub *)

\* NodeSessions.ingest/4: Mirror.place/3 accepts the next offset, and the
\* record's Mirror.effect/1 is applied (apply_effect/3), in one Durable.Store
\* commit (signals included).
ApplyRecord(rec) ==
    LET acc == {i \in Inputs : inState[i] = "accepted"} IN
    CASE rec[1] = "in" ->
            /\ inState' = IF rec[2] \in Inputs /\ inState[rec[2]] = "queued"
                            THEN [inState EXCEPT ![rec[2]] = "accepted"]
                            ELSE inState
            /\ UNCHANGED <<inAns, sigCount>>
      [] rec[1] \in {"idle", "stopped"} ->
            \* settle_inputs: every accepted input is done with the answer;
            \* "stopped" carries no answer, so it is the fixed text (-2).
            LET ans == IF rec[1] = "stopped" THEN -2 ELSE rec[2] IN
            /\ inState' = [i \in Inputs |-> IF i \in acc THEN "done" ELSE inState[i]]
            /\ inAns' = [i \in Inputs |-> IF i \in acc THEN ans ELSE inAns[i]]
            /\ Fire(acc)
      [] OTHER -> UNCHANGED <<inState, inAns, sigCount>>

Ingest(off, rec) ==
    IF hubSession /\ off = Len(hubLog) THEN
        /\ hubLog' = Append(hubLog, rec)
        /\ ApplyRecord(rec)
        /\ UNCHANGED h2n
    ELSE IF hubSession /\ off > Len(hubLog) THEN
        \* {:gap, expected} -> push "resync"
        /\ h2n' = Append(h2n, <<"resync", Len(hubLog)>>)
        /\ UNCHANGED <<hubLog, inState, inAns, sigCount>>
    ELSE \* :duplicate or :ignored
        UNCHANGED <<hubLog, inState, inAns, sigCount, h2n>>

\* reject_input/3: a queued input fails and its signal is recorded, in one
\* commit.
Reject(i) ==
    IF inState[i] = "queued"
    THEN /\ inState' = [inState EXCEPT ![i] = "failed"]
         /\ Fire({i})
    ELSE UNCHANGED <<inState, sigCount>>

\* The NodeChannel process handles one pushed message.
HubRecv ==
    /\ chan = "up" /\ n2h # <<>>
    /\ n2h' = Tail(n2h)
    /\ LET m == Head(n2h) IN
       IF m[1] = "rej"
         THEN /\ Reject(m[2])
              /\ UNCHANGED <<h2n, hubLog, inAns>>
         ELSE Ingest(m[2], m[3])
    /\ UNCHANGED <<log, connV, coordV, reply, hubSession, hubMemV, budgetV>>

\* The channel of a dropped socket terminates and unregisters.
HubChanDown ==
    /\ chan = "stale"
    /\ chan' = "none"
    /\ UNCHANGED <<log, connV, coordV, wireV, hubDbV, pushed, sigCount, budgetV>>

\* start/3 inserts the session row (a Durable.Store commit of its own).
HubCreateSession ==
    /\ ~hubSession
    /\ hubSession' = TRUE
    /\ UNCHANGED <<log, connV, coordV, wireV, hubLog, inState, inAns, hubMemV,
                   sigCount, budgetV>>

\* send_input/3: insert the input as queued (one Durable.Store commit), then
\* push it if the node is online. Inputs are inserted in id order.
HubSendInput(i) ==
    /\ hubSession /\ inState[i] = "none"
    /\ \A j \in Inputs : j < i => inState[j] # "none"
    /\ inState' = [inState EXCEPT ![i] = "queued"]
    /\ Command(<<"input", i>>)
    /\ UNCHANGED <<log, connV, coordV, n2h, reply, hubSession, hubLog, inAns,
                   chan, sigCount, budgetV>>

\* send_input/start again with an id the hub already has (NodeWork reruns
\* a tool call after a hub restart with the same ids; send_input racing a
\* join gives the same pair of messages). The insert is a no-op, and the
\* input is pushed only while it is still queued; the channel drops a
\* second push of the same id.
HubRepush(i) ==
    /\ hubSession /\ inState[i] # "none" /\ nRepush < MaxRepush
    /\ nRepush' = nRepush + 1
    /\ IF inState[i] = "queued" THEN Command(<<"input", i>>) ELSE UNCHANGED <<h2n, pushed>>
    /\ UNCHANGED <<log, connV, coordV, n2h, reply, hubDbV, chan, sigCount,
                   nDisc, nNodeRst, nHubRst, nCrash, nRej, nStop>>

\* stop/1
HubStop ==
    /\ hubSession /\ nStop < MaxStops
    /\ nStop' = nStop + 1
    /\ Command(<<"stop", 0>>)
    /\ UNCHANGED <<log, connV, coordV, n2h, reply, hubDbV, chan, sigCount,
                   nDisc, nNodeRst, nHubRst, nCrash, nRej, nRepush>>

-----------------------------------------------------------------------------
(* Faults *)

\* The websocket drops (or the channel or the Connection process crashes):
\* in-flight pushes both ways are lost, the hub's channel lingers until it
\* notices, and the Connection reconnects. A delivery call in progress
\* still completes (the Connection handles the drop after it returns).
Disconnect ==
    /\ conn # "down" /\ nDisc < MaxDisconnects
    /\ nDisc' = nDisc + 1
    /\ conn' = "down" /\ sent' = -1 /\ nq' = <<>>
    /\ h2n' = <<>> /\ n2h' = <<>> /\ reply' = -1
    /\ chan' = IF chan = "up" THEN "stale" ELSE chan
    /\ UNCHANGED <<log, dlv, coordV, hubDbV, pushed, sigCount,
                   nNodeRst, nHubRst, nCrash, nRej, nStop, nRepush>>

\* The hub restarts: SQLite survives; channels and the registry do not.
\* The node sees a disconnect.
HubRestart ==
    /\ nHubRst < MaxHubRestarts
    /\ nHubRst' = nHubRst + 1
    /\ chan' = "none" /\ pushed' = {}
    /\ conn' = "down" /\ sent' = -1 /\ nq' = <<>>
    /\ h2n' = <<>> /\ n2h' = <<>> /\ reply' = -1
    /\ UNCHANGED <<log, dlv, coordV, hubDbV, sigCount,
                   nDisc, nNodeRst, nCrash, nRej, nStop, nRepush>>

\* The node VM restarts: the log survives (every append is fsynced before
\* it is announced). PhotonNode starts a new Connection and runs
\* Harness.resume_all, which starts coordinators for sessions that were
\* working (Harness.working?/1).
NodeRestart ==
    /\ nNodeRst < MaxNodeRestarts
    /\ nNodeRst' = nNodeRst + 1
    /\ conn' = "down" /\ sent' = -1 /\ nq' = <<>> /\ dlv' = 0
    /\ h2n' = <<>> /\ n2h' = <<>> /\ reply' = -1
    /\ chan' = IF chan = "up" THEN "stale" ELSE chan
    /\ IF Working(log) THEN CoordReset(log, <<>>) ELSE CoordDown
    \* A stop still in the lost delivery call is gone with the VM (the hub
    \* doesn't resend stops); one already in the log is re-armed.
    /\ stopAsk' = FALSE
    /\ UNCHANGED <<log, hubDbV, pushed, sigCount,
                   nDisc, nHubRst, nCrash, nRej, nStop, nRepush>>

-----------------------------------------------------------------------------
Next ==
    \/ CoordInput \/ CoordDecide \/ CoordResponse \/ CoordIdleTimer \/ CoordIdleStop
    \/ CoordCrash
    \/ NodeConnect \/ NodeHandleJoin \/ NodeNotify
    \/ NodeRecvInput \/ NodeRecvResync \/ NodeRecvStop
    \/ HubRecv \/ HubChanDown
    \/ HubCreateSession \/ HubStop
    \/ \E i \in Inputs : HubSendInput(i) \/ HubRepush(i)
    \/ Disconnect \/ HubRestart \/ NodeRestart

\* Processes take their steps; the model answers; an idle coordinator
\* eventually stops; the node keeps reconnecting. User actions (create,
\* send, stop), the idle-timer race and faults get no fairness, and faults
\* are bounded, so every behavior ends with stable connectivity.
Fairness ==
    /\ WF_vars(CoordInput) /\ WF_vars(CoordDecide) /\ WF_vars(CoordResponse)
    /\ WF_vars(CoordIdleStop)
    /\ WF_vars(NodeConnect) /\ WF_vars(NodeHandleJoin)
    /\ WF_vars(NodeNotify) /\ WF_vars(NodeRecvInput) /\ WF_vars(NodeRecvResync)
    /\ WF_vars(NodeRecvStop)
    /\ WF_vars(HubRecv) /\ WF_vars(HubChanDown)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* Safety *)

TypeOK ==
    /\ conn \in {"down", "joining", "up"}
    /\ cpc \in {"wait", "drain", "start", "stopping"}
    /\ chan \in {"none", "stale", "up"}
    /\ \A i \in Inputs : inState[i] \in {"none", "queued", "accepted", "done", "failed"}
    /\ pushed \subseteq Inputs
    /\ dlv \in Inputs \cup {0, -1}
    /\ stopAsk \in BOOLEAN
    /\ sent \in -1..Len(log)

\* The hub's copy is always a prefix of the node's log.
HubPrefix ==
    /\ Len(hubLog) <= Len(log)
    /\ hubLog = SubSeq(log, 1, Len(hubLog))

\* Each input id is accepted into the node log at most once.
InputAtMostOnce ==
    \A i \in Inputs : Cardinality({k \in 1..Len(log) : log[k] = <<"in", i>>}) <= 1

\* The signal is recorded at most once per input.
SignalAtMostOnce == \A i \in Inputs : sigCount[i] <= 1

\* The hub only calls an input accepted or done once it holds its record.
HubAcceptedInLog ==
    \A i \in Inputs : inState[i] \in {"accepted", "done"} =>
        \E k \in 1..Len(hubLog) : hubLog[k] = <<"in", i>>

\* A settled or rejected input always has its signal (one commit).
SettledHasSignal ==
    \A i \in Inputs : inState[i] \in {"done", "failed"} => sigCount[i] >= 1

HubIdx(i) == CHOOSE k \in 1..Len(hubLog) : hubLog[k] = <<"in", i>>

\* No input is settled with the answer of a run that finished before the
\* input was accepted: no idle/stopped record lies between the model
\* response that produced the answer and the input's record.
NoStaleAnswer ==
    \A i \in Inputs : (inState[i] = "done" /\ inAns[i] >= 0) =>
        ~\E s \in 1..Len(hubLog) :
            /\ hubLog[s][1] \in {"idle", "stopped"}
            /\ inAns[i] + 1 < s /\ s < HubIdx(i)

\* Stricter: the answer was produced after the input was accepted.
AnswerAfterInput ==
    \A i \in Inputs : (inState[i] = "done" /\ inAns[i] >= 0) =>
        inAns[i] > HubIdx(i) - 1

\* An input the hub settled as failed never runs on the node.
RejectedNeverRuns == \A i \in Inputs : inState[i] = "failed" => ~InLog(i)

\* Once a hard stop is in the log, the next run-state record is "stopped"
\* (so the inputs it settles get "Stopped before finishing.").
Min(S) == CHOOSE x \in S : \A y \in S : x <= y
StatesAfter(k) == {j \in (k + 1)..Len(log) : log[j][1] \in {"run", "idle", "stopped"}}
StopHonored ==
    \A k \in 1..Len(log) :
        (log[k][1] = "ctl" /\ StatesAfter(k) # {}) =>
            log[Min(StatesAfter(k))][1] = "stopped"

\* No external input is logged between a hard stop and its "stopped"
\* record (input that arrives meanwhile waits and gets its own turn).
NoInputDuringStop ==
    \A k \in 1..Len(log) :
        log[k][1] = "ctl" =>
            ~\E j \in (k + 1)..Len(log) :
                /\ log[j][1] = "in"
                /\ ~\E s \in (k + 1)..(j - 1) : log[s][1] = "stopped"

-----------------------------------------------------------------------------
(* Liveness (under the bounded faults, i.e. eventually stable connectivity) *)

\* The hub's copy converges to the node log.
Converges == <>[](hubSession => hubLog = log)

\* Every queued input is eventually accepted into the node log (or rejected).
QueuedAccepted ==
    \A i \in Inputs : (inState[i] = "queued") ~> (InLog(i) \/ inState[i] = "failed")

\* Every input in the node log is eventually settled on the hub and its
\* signal recorded.
AcceptedSettled ==
    \A i \in Inputs : InLog(i) ~> (inState[i] \in {"done", "failed"} /\ sigCount[i] >= 1)

\* Every settled input eventually has its signal.
SettledSignaled ==
    \A i \in Inputs : (inState[i] \in {"done", "failed"}) ~> (sigCount[i] >= 1)

\* A stop the node takes while the session is working gets its hard stop
\* input into the log (unless the node VM restarts first; the hub doesn't
\* resend a stop). StopHonored then makes "stopped" the next run state.
StopTakesEffect == stopAsk ~> ~stopAsk

=============================================================================
