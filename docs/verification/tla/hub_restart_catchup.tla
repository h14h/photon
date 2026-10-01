------------------------------ MODULE hub_restart_catchup ------------------------------
(***************************************************************************
Photon verification, layer 3. Spec B: hub restart and catch-up.

Aligned with the protocol comment in node/lib/photon_node.ex:

  * join params are static info; the join reply is
    %{"sync" => %{session_id => offset}}, how many events the hub
    already holds (Photon.Sessions.sync_for/1, cursor = line count
    minus event_base). This model has one session and event_base 0,
    so the sync offset is Len(hubLog).
  * the node replays strictly past those offsets (PhotonNode.Connection
    replay/3), then would push "status". Status is not a log record
    and is omitted here.
  * node -> server "event" carries session_id, offset, event.
    Photon.Sessions.ingest/4 appends only when offset is the cursor,
    returns :duplicate when offset is behind, and {:gap, expected}
    when offset is ahead. The channel then pushes "resync".
  * runs keep going while disconnected. PhotonNode.Run appends to
    EventLog before it notifies Connection, and Connection drops the
    notify when the socket is not joined. The bytes stay in the node
    log and ride the next replay.

IDEALIZED, on purpose:
  One session, one node, at most MaxLen records (the cfg uses 3).
  No start_run, attachments, delete_session, or second node.
  Offsets are 0-based line indexes, matching EventLog.append/2.
  kind "done" stands in for the durable {"type":"exit"} event that
  PhotonNode.Run writes immediately before
  Connection.notify({:run_finished, ...}). The "run_finished" channel
  frame itself is NOT queued across a disconnect. "Don't lose an
  offline run_finished" in this spec means: don't lose that exit
  record. A podman oracle must look for "type":"exit" in the two
  jsonl files, not for a replayed Phoenix frame.
  HubCrash keeps hubLog. That is the volume
  ($PHOTON_DATA_DIR/sessions/<id>/events.jsonl). The channel dies, so
  the link goes down with the process.
  NoticeGap jumps `sent` two ahead without appending, which is the
  hub observing a hole. The real node does not bump its watermark on
  a rejected push; the action is the bad delivery the hub must refuse,
  followed by Resync snapping `sent` back to the cursor the way
  handle_message "resync" calls replay(socket, id, from).

Liveness sketch, NOT checked:
  (link /\ hubAlive /\ ~ENABLED CommitMsg /\ ~ENABLED CommitDone
     /\ no further Disconnect or HubCrash)
    leads-to Len(hubLog) = Len(nodeLog)
  under weak fairness of Deliver, Resync, and Rejoin.
  That state is "after catch-up, hub high-water covers every committed
  offset". It is intentionally false in the state Rejoin produces,
  where sent = Len(hubLog) and the node log may be longer. Safety
  (HubIsPrefix, HighWaterBounded) holds there; the drain is liveness.
  Crash and disconnect stay enabled forever in Spec, so a PROPERTY
  of bare Spec would fail. Restrict the model before checking it.
***************************************************************************)

EXTENDS Integers, Sequences

CONSTANT MaxLen

ASSUME MaxLen \in 1..4

VARIABLES
  nodeLog,    \* records [off |-> Nat, kind |-> "msg" or "done"], node EventLog
  hubLog,     \* the hub's events.jsonl, on the volume
  link,       \* TRUE while the node channel is joined
  hubAlive,   \* FALSE after HubCrash, before HubRestart. Volume is hubLog.
  sent,       \* next offset the node will push (Connection assign `sent`)
  gap,        \* TRUE after a skipped offset, until Resync
  drops       \* duplicate deliveries the hub ignored (bounded counter)

vars == <<nodeLog, hubLog, link, hubAlive, sent, gap, drops>>

NoDone(log) ==
  \A i \in DOMAIN log: log[i].kind # "done"

TypeOK ==
  /\ Len(nodeLog) <= MaxLen
  /\ Len(hubLog) <= MaxLen
  /\ \A i \in DOMAIN nodeLog:
       /\ nodeLog[i].off \in 0..MaxLen
       /\ nodeLog[i].kind \in {"msg", "done"}
  /\ \A i \in DOMAIN hubLog:
       /\ hubLog[i].off \in 0..MaxLen
       /\ hubLog[i].kind \in {"msg", "done"}
  /\ link \in BOOLEAN
  /\ hubAlive \in BOOLEAN
  /\ sent \in 0..(MaxLen + 2)
  /\ gap \in BOOLEAN
  /\ drops \in 0..2

Init ==
  /\ nodeLog = <<>>
  /\ hubLog = <<>>
  /\ link = FALSE
  /\ hubAlive = TRUE
  /\ sent = 0
  /\ gap = FALSE
  /\ drops = 0

\* ---- the run does not need the socket ----

CommitMsg ==
  /\ Len(nodeLog) < MaxLen
  /\ NoDone(nodeLog)
  /\ nodeLog' = Append(nodeLog, [off |-> Len(nodeLog), kind |-> "msg"])
  /\ UNCHANGED <<hubLog, link, hubAlive, sent, gap, drops>>

\* Terminal exit record. May be the first line or a later one. Nothing
\* is appended after it (the run process has stopped).
CommitDone ==
  /\ Len(nodeLog) < MaxLen
  /\ NoDone(nodeLog)
  /\ nodeLog' = Append(nodeLog, [off |-> Len(nodeLog), kind |-> "done"])
  /\ UNCHANGED <<hubLog, link, hubAlive, sent, gap, drops>>

\* ---- link and the hub process ----

\* Join reply: sync offset is the hub cursor. Clears a stale gap flag
\* because the new channel will replay from `from`, not from the skipped
\* watermark.
Rejoin ==
  /\ hubAlive = TRUE
  /\ link = FALSE
  /\ link' = TRUE
  /\ sent' = Len(hubLog)
  /\ gap' = FALSE
  /\ UNCHANGED <<nodeLog, hubLog, hubAlive, drops>>

Disconnect ==
  /\ link = TRUE
  /\ link' = FALSE
  /\ UNCHANGED <<nodeLog, hubLog, hubAlive, sent, gap, drops>>

\* Process dies. events.jsonl (hubLog) is untouched.
HubCrash ==
  /\ hubAlive = TRUE
  /\ hubAlive' = FALSE
  /\ link' = FALSE
  /\ UNCHANGED <<nodeLog, hubLog, sent, gap, drops>>

\* After a crash the link is already down, so this returns to a state
\* Disconnect can also reach (alive, unlinked, logs unchanged). Coverage
\* may show HubRestart adding no new distinct states. HubCrash is the
\* state that is new: the process is down and hubLog is still the prefix.
HubRestart ==
  /\ hubAlive = FALSE
  /\ hubAlive' = TRUE
  /\ UNCHANGED <<nodeLog, hubLog, link, sent, gap, drops>>

\* ---- deliver, drop, gap, resync ----

\* Next offset matches the cursor. Append that one node record.
Deliver ==
  /\ link = TRUE
  /\ hubAlive = TRUE
  /\ gap = FALSE
  /\ sent = Len(hubLog)
  /\ sent < Len(nodeLog)
  /\ hubLog' = Append(hubLog, nodeLog[sent + 1])
  /\ sent' = sent + 1
  /\ UNCHANGED <<nodeLog, link, hubAlive, gap, drops>>

\* ingest returned :duplicate. The hub file does not grow.
DropSeen ==
  /\ link = TRUE
  /\ hubAlive = TRUE
  /\ gap = FALSE
  /\ Len(hubLog) > 0
  /\ drops < 2
  /\ drops' = drops + 1
  /\ UNCHANGED <<nodeLog, hubLog, link, hubAlive, sent, gap>>

\* A push ahead of the cursor. Hub must not append. Enabled only when
\* at least one real record sits in the hole (so the jump is a skip,
\* not a send past the end of the node log).
NoticeGap ==
  /\ link = TRUE
  /\ hubAlive = TRUE
  /\ gap = FALSE
  /\ sent = Len(hubLog)
  /\ Len(hubLog) + 1 < Len(nodeLog)
  /\ sent' = Len(hubLog) + 2
  /\ gap' = TRUE
  /\ UNCHANGED <<nodeLog, hubLog, link, hubAlive, drops>>

\* Channel pushes resync with from = the hub cursor. Node watermark
\* snaps back; Deliver can then replay the hole and everything after it.
Resync ==
  /\ link = TRUE
  /\ hubAlive = TRUE
  /\ gap = TRUE
  /\ sent' = Len(hubLog)
  /\ gap' = FALSE
  /\ UNCHANGED <<nodeLog, hubLog, link, hubAlive, drops>>

Next ==
  \/ CommitMsg
  \/ CommitDone
  \/ Rejoin
  \/ Disconnect
  \/ HubCrash
  \/ HubRestart
  \/ Deliver
  \/ DropSeen
  \/ NoticeGap
  \/ Resync

Spec == Init /\ [][Next]_vars

\* Link is up only while the hub process is up. (HubCrash clears both.)
LinkNeedsHub ==
  (link = TRUE) => (hubAlive = TRUE)

\* Hub log is exactly the prefix of the node log of that length.
\* Same records, same order, so each offset appears at most once and
\* the hub never invents an event the node did not commit.
HubIsPrefix ==
  /\ Len(hubLog) <= Len(nodeLog)
  /\ \A i \in 1..Len(hubLog): hubLog[i] = nodeLog[i]

ExactlyOnce ==
  \A i, j \in 1..Len(hubLog):
    (hubLog[i].off = hubLog[j].off) => (i = j)

\* Offsets are line indexes on both sides.
OffsetsAreIndexes ==
  /\ \A i \in 1..Len(nodeLog): nodeLog[i].off = i - 1
  /\ \A i \in 1..Len(hubLog): hubLog[i].off = i - 1

\* The offline exit is still in the node log (no action deletes it),
\* it is the only done record, and if the hub has already accepted that
\* offset the kinds match. This is the safety half of "don't lose
\* run_finished". The liveness half is the sketch in the header.
DoneSurvives ==
  \A i \in 1..Len(nodeLog):
    (nodeLog[i].kind = "done") =>
      /\ \A j \in 1..Len(nodeLog): (nodeLog[j].kind = "done") => (j = i)
      /\ (i <= Len(hubLog) => hubLog[i].kind = "done")

\* Hub high-water never runs past the offsets the node has committed.
\* "After reconnect, high-water >= committed" is the caught-up state
\* (CaughtUp below), which Deliver reaches and which Rejoin alone does not.
HighWaterBounded ==
  Len(hubLog) <= Len(nodeLog)

\* With no gap open, the node watermark is the hub cursor (true right
\* after Rejoin, and again after each Deliver). With a gap open, the
\* watermark is exactly two ahead, which is what NoticeGap sets and
\* what Resync undoes.
CursorAgrees ==
  /\ (gap = FALSE) => (sent = Len(hubLog))
  /\ (gap = TRUE) => (sent = Len(hubLog) + 2)

\* The drained state: link up, no hole, hub holds every committed offset.
\* Not an invariant by itself (replay in progress violates the predicate).
\* When the predicate holds, done is in the hub log if the node committed it.
CaughtUp ==
  /\ link = TRUE
  /\ hubAlive = TRUE
  /\ gap = FALSE
  /\ Len(hubLog) = Len(nodeLog)

DoneCaughtUp ==
  CaughtUp =>
    (\A i \in 1..Len(nodeLog):
      (nodeLog[i].kind = "done") => (hubLog[i].kind = "done"))

=============================================================================
