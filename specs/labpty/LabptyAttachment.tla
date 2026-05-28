----------------------------- MODULE LabptyAttachment -----------------------------
(****************************************************************************
 Labpty per-session connected-client counter, modelled for TLC (ADR 0010).

 What this spec covers
   A labpty session carries a bitmask of the client connections currently
   attached to it (`attached_clients` in labpty_session_t). The
   connected-client count surfaced in the descriptor is its popcount. The
   model abstracts the bitmask as a set of client ids per session:

     - inUse[c]    : 1 while client slot c holds a live control socket
     - alive[s]    : 1 while session s exists in the registry
     - attached[s] : the set of clients attached to session s, i.e.
                     Cardinality(attached[s]) is the descriptor's
                     connected_clients

   Actions mirror Sources/Labpty/main.c:
     - Connect / Disconnect : add_client and client_release on the socket
     - OpenSession          : handle_open, auto-attaching the opener
     - Attach / Detach      : handle_attach / handle_detach
     - TerminateSession     : the registry slot is freed, mask cleared

 The load-bearing claim
   The count is popcount(mask) computed on demand; there is no cached
   counter. So correctness reduces to one safety property: a client that is
   gone must not remain in any mask. client_release is the single funnel
   that scrubs a departing client's bit from every session, so

     AttachmentImpliesInUse : c \in attached[s] => inUse[c] = 1

   must be invariant. If any teardown path forgets to scrub, the count
   overcounts a departed owner: a live-but-abandoned session would look
   owned (blocking adoption) or a dead owner would be counted. The constant
   TeardownSkipsAttachmentScrub models that regression.

 Companion modules
   MC_Attachment.cfg        (scrub on)  -> every invariant holds.
   MC_AttachmentPreFix.cfg  (scrub off) -> AttachmentImpliesInUse fails,
                                           the stale-attachment overcount.
   Same positive/negative-control split as LabptyControlChannel and its
   PreFix companion.
 ****************************************************************************)

EXTENDS Naturals, FiniteSets

CONSTANTS
    Clients,                      \* finite set of client slot ids (~ LABPTY_MAX_CLIENTS)
    Sessions,                     \* finite set of session ids (~ registry slots)
    TeardownSkipsAttachmentScrub  \* BOOLEAN; TRUE = regression where
                                  \* client_release stops scrubbing masks.

ASSUME TeardownSkipsAttachmentScrub \in BOOLEAN

VARIABLES
    inUse,      \* [Clients -> 0..1]
    alive,      \* [Sessions -> 0..1]
    attached    \* [Sessions -> SUBSET Clients]

vars == << inUse, alive, attached >>

TypeOK ==
    /\ inUse \in [ Clients -> 0..1 ]
    /\ alive \in [ Sessions -> 0..1 ]
    /\ attached \in [ Sessions -> SUBSET Clients ]

Init ==
    /\ inUse    = [ c \in Clients  |-> 0 ]
    /\ alive    = [ s \in Sessions |-> 0 ]
    /\ attached = [ s \in Sessions |-> {} ]

\* ----------------------------------------------------------------------
\* Actions
\* ----------------------------------------------------------------------

\* add_client: a socket is accepted into a free slot.
Connect(c) ==
    /\ inUse[c] = 0
    /\ inUse' = [ inUse EXCEPT ![c] = 1 ]
    /\ UNCHANGED << alive, attached >>

\* client_release: the socket goes away (poll fault, idle/frame expiry,
\* shutdown). The bit is scrubbed from every session unless the modelled
\* regression drops the scrub.
Disconnect(c) ==
    /\ inUse[c] = 1
    /\ inUse' = [ inUse EXCEPT ![c] = 0 ]
    /\ attached' =
            IF TeardownSkipsAttachmentScrub
            THEN attached
            ELSE [ s \in Sessions |-> attached[s] \ {c} ]
    /\ UNCHANGED alive

\* handle_open: a connected client opens a fresh session and is implicitly
\* attached. memset zeroes the slot, so the new mask is exactly {c} even if
\* a prior session reused this slot.
OpenSession(c, s) ==
    /\ inUse[c] = 1
    /\ alive[s] = 0
    /\ alive' = [ alive EXCEPT ![s] = 1 ]
    /\ attached' = [ attached EXCEPT ![s] = {c} ]
    /\ UNCHANGED inUse

\* handle_attach: a connected client claims an already-open session
\* (reattach-after-restart, adopt-orphan). Idempotent via set union.
Attach(c, s) ==
    /\ inUse[c] = 1
    /\ alive[s] = 1
    /\ attached' = [ attached EXCEPT ![s] = attached[s] \cup {c} ]
    /\ UNCHANGED << inUse, alive >>

\* handle_detach: a connected client releases a claim without terminating.
\* Idempotent via set difference.
Detach(c, s) ==
    /\ inUse[c] = 1
    /\ attached' = [ attached EXCEPT ![s] = attached[s] \ {c} ]
    /\ UNCHANGED << inUse, alive >>

\* handle_terminate + reap: the session slot is freed, its mask cleared.
TerminateSession(s) ==
    /\ alive[s] = 1
    /\ alive' = [ alive EXCEPT ![s] = 0 ]
    /\ attached' = [ attached EXCEPT ![s] = {} ]
    /\ UNCHANGED inUse

Next ==
    \/ \E c \in Clients : Connect(c)
    \/ \E c \in Clients : Disconnect(c)
    \/ \E c \in Clients, s \in Sessions : OpenSession(c, s)
    \/ \E c \in Clients, s \in Sessions : Attach(c, s)
    \/ \E c \in Clients, s \in Sessions : Detach(c, s)
    \/ \E s \in Sessions : TerminateSession(s)

Spec == Init /\ [][Next]_vars

\* ----------------------------------------------------------------------
\* Safety invariants
\* ----------------------------------------------------------------------

\* The load-bearing property: no mask retains a client that has gone away.
\* This is exactly what client_release's scrub guarantees and what the
\* connected-client count depends on to not overcount a departed owner.
AttachmentImpliesInUse ==
    \A s \in Sessions : \A c \in attached[s] : inUse[c] = 1

\* No attachment outlives the session it points at: terminate clears the
\* mask and a reused slot reopens at {opener}, so a dead session never
\* carries a phantom owner.
AttachmentImpliesAlive ==
    \A s \in Sessions : attached[s] # {} => alive[s] = 1

\* The count surfaced in the descriptor never exceeds the client pool.
CountWithinBounds ==
    \A s \in Sessions : Cardinality(attached[s]) <= Cardinality(Clients)

=============================================================================
