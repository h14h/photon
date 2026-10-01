----------------------------- MODULE install_clean_machine -----------------------------
(***************************************************************************
Photon verification, layer 3. Spec A: clean-machine install to online.

One machine, one node id. The question is when the hub is allowed to believe
that id is online.

Grounded in:
  README "Add nodes" (curl one-liner, or Provision over SSH)
  priv/node/install.sh.eex
      PHOTON_NODE_TOKEN required, binary placed, user service started,
      then the process dials. PHOTON_INSTALL_OK is printed after that.
  Photon.Provision.steps(:install)
      probe, upload, install script, wait_for_node. The hub only reports
      success once Nodes.get shows a connection at-or-after the install.
  PhotonWeb.NodeSocket
      connect/3 requires header x-photon-token. A bad token never joins.
  PhotonWeb.NodeChannel.join/3 and replace_existing/1
      Registry key is the node id. A second join closes the previous
      channel before the new one is the one callers see. Online means
      that registry entry exists (the sidebar's green dot).

IDEALIZED, on purpose:
  No SSH, no Tailscale, no binary bytes, no systemd unit text.
  "registered" is 0 or 1, not a set of pids. replace_existing is the
  Replace action: a later join does not bump the count to 2.
  DialWithoutToken is a misconfigured machine (empty token) that skips
  the happy path. The real installer refuses to start without
  PHOTON_NODE_TOKEN; the action exists so TLC visits the reject path
  NodeSocket actually has.
  FailMidInstall collapses "download failed", "binary would not start",
  "service never came up", and "dial did not complete" into one terminal.
  A crash after Joined is a different problem (the node really did
  register) and is not this spec.

Liveness sketch, NOT checked (CHECK_DEADLOCK FALSE, no PROPERTY):
  If tokenOK and FailMidInstall / RejectBadToken are never taken, weak
  fairness on IssueToken, PlaceBinary, StartService, BeginDial, and Join
  leads to phase = "joined". Those failure actions stay in Next, so
  "eventually joined" is false of Spec and would only become true in a
  restricted next-state relation. Do not add WF_vars(Next) and expect
  a liveness property to hold.
***************************************************************************)

EXTENDS Integers

VARIABLES
  phase,        \* install progress on the machine
  tokenOK,      \* TRUE only after the hub token is in the install environment
  registered,   \* live "node:<id>" registrations. The hub's online bit.
  joinCount     \* how many successful joins this run has accepted (bounded)

vars == <<phase, tokenOK, registered, joinCount>>

Phases == {
  "absent",          \* nothing installed; hub has no entry for this id
  "token_known",     \* PHOTON_NODE_TOKEN is set
  "binary_placed",   \* ~/.local/share/photon-node/bin/photon-node is in place
  "service_up",      \* systemd, launchd, or the nohup fallback has started it
  "dialing",         \* process is opening the websocket
  "joined",          \* channel is registered; sidebar would show a green dot
  "failed"           \* stopped before a successful join
}

TypeOK ==
  /\ phase \in Phases
  /\ tokenOK \in BOOLEAN
  /\ registered \in {0, 1}
  /\ joinCount \in 0..2

Init ==
  /\ phase = "absent"
  /\ tokenOK = FALSE
  /\ registered = 0
  /\ joinCount = 0

\* ---- happy path: Absent -> TokenKnown -> BinaryPlaced -> ServiceUp
\*                  -> Dialing -> Joined

IssueToken ==
  /\ phase = "absent"
  /\ phase' = "token_known"
  /\ tokenOK' = TRUE
  /\ UNCHANGED <<registered, joinCount>>

PlaceBinary ==
  /\ phase = "token_known"
  /\ tokenOK = TRUE
  /\ phase' = "binary_placed"
  /\ UNCHANGED <<tokenOK, registered, joinCount>>

StartService ==
  /\ phase = "binary_placed"
  /\ phase' = "service_up"
  /\ UNCHANGED <<tokenOK, registered, joinCount>>

BeginDial ==
  /\ phase = "service_up"
  /\ phase' = "dialing"
  /\ UNCHANGED <<tokenOK, registered, joinCount>>

\* Successful join. Sets the count to 1 rather than adding one, which is
\* the same rule Replace uses: the registry key is unique.
Join ==
  /\ phase = "dialing"
  /\ tokenOK = TRUE
  /\ registered = 0
  /\ phase' = "joined"
  /\ registered' = 1
  /\ joinCount' = joinCount + 1
  /\ UNCHANGED tokenOK

\* A reconnect of an already-joined node. replace_existing/1 closes the
\* old channel; the live count stays 1. joinCount only records that TLC
\* took this step (bounded so the state space stays finite).
Replace ==
  /\ phase = "joined"
  /\ tokenOK = TRUE
  /\ registered = 1
  /\ joinCount < 2
  /\ joinCount' = joinCount + 1
  /\ registered' = 1
  /\ UNCHANGED <<phase, tokenOK>>

\* ---- failures that must not look like "online"

\* Misconfigured dial: no token was ever issued. Reachable from absent so
\* the reject path is not dead code under TLC.
DialWithoutToken ==
  /\ phase = "absent"
  /\ tokenOK = FALSE
  /\ phase' = "dialing"
  /\ UNCHANGED <<tokenOK, registered, joinCount>>

\* Installer died, download failed, binary would not run, or the dial
\* never completed. The hub has not registered this id.
FailMidInstall ==
  /\ phase \in {"token_known", "binary_placed", "service_up", "dialing"}
  /\ phase' = "failed"
  /\ registered' = 0
  /\ UNCHANGED <<tokenOK, joinCount>>

\* NodeSocket returns :error. No channel, no registry entry.
RejectBadToken ==
  /\ phase = "dialing"
  /\ tokenOK = FALSE
  /\ phase' = "failed"
  /\ registered' = 0
  /\ UNCHANGED <<tokenOK, joinCount>>

Next ==
  \/ IssueToken
  \/ PlaceBinary
  \/ StartService
  \/ BeginDial
  \/ DialWithoutToken
  \/ Join
  \/ Replace
  \/ FailMidInstall
  \/ RejectBadToken

Spec == Init /\ [][Next]_vars

\* ---- invariants (safety). These are the spec. ----

\* At most one live registration for this node id.
AtMostOneLive == registered <= 1

\* Joined only with a token the hub issued.
NoJoinedWithoutToken ==
  (phase = "joined") => (tokenOK = TRUE)

\* The hub's online bit is exactly "phase = joined". A green dot in any
\* earlier phase, or a missing dot while joined, is the bug.
HubOnlineIffJoined ==
  (registered = 1) <=> (phase = "joined")

\* Failed mid-install never leaves the hub believing this node is online.
\* Podman oracle: after killing the install before the websocket comes up,
\* the sidebar has no green dot on this id. (An id that never joined is
\* also absent from the offline list, unless some session already names it.
\* "Not online" is the property. "Shows the word offline" is not.)
FailedStaysOffline ==
  (phase = "failed") => (registered = 0)

\* Token is issued exactly when we leave "absent" on the happy path, and
\* a dial with no token is the only way to be dialing while tokenOK = FALSE.
TokenMatchesPhase ==
  /\ (phase = "absent") => (tokenOK = FALSE)
  /\ (tokenOK = TRUE) => phase \in {
       "token_known", "binary_placed", "service_up", "dialing", "joined", "failed"
     }

\* joinCount moves only on the joined node, and only once we have joined.
JoinCountMatches ==
  /\ (phase = "joined") => joinCount \in {1, 2}
  /\ (phase # "joined") => joinCount = 0

=============================================================================
