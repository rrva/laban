-------------------------- MODULE LabptyReuse --------------------------
(****************************************************************************
 The logical_id reuse contract of labpty_registry.c.

 Why this spec exists
   LabptyLifecycle.tla models the slot lifecycle but has NO logical_id, so
   it could only prove that a close_pending slot is EVENTUALLY released
   (EventualReleaseOfClosePending) — not that the id that slot held is
   reusable the instant the session goes not-alive. The integration test
   testRapidOpenTerminateSameLogicalIdSurvives hit exactly that gap: a client
   terminated a logical_id and immediately reopened it, racing the
   asynchronous reap tick, and got SESSION_ID_IN_USE.

   The fix decouples logical_id reuse from child reaping:
   labpty_session_request_close RELINQUISHES the logical_id the moment the
   client terminates (the slot keeps reaping under no id), so a reopen finds
   no holder and never races the reap tick — and the open path never blocks
   the single-threaded event loop waiting for a child to die. (An earlier fix
   that blocked in open is commit 389df73; this is its non-blocking
   successor.)

   This module adds the variable the old spec lacked (logical_id) and states
   the property it could not express (TerminatedIdIsReusable) plus the
   mechanism invariant (NotAliveImpliesIdRelinquished). The Fixed constant
   selects terminate's behaviour:

     Fixed = TRUE  : terminate relinquishes the id. A terminated id is
                     immediately reusable; no close_pending slot retains one.
     Fixed = FALSE : terminate keeps the id while close_pending. TLC finds the
                     terminate->reopen rejection — the negative control
                     (MC_ReusePreFix.cfg), pinning the bug-shape so it cannot
                     silently return.

   Note the bug is NOT a violation of eventual release: ReapTick still frees
   the slot. The property is about IMMEDIACY — reuse without waiting for a
   tick — which is precisely why a liveness-only model missed it.
 ****************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    MaxSessions,   \* registry slots (LABPTY_MAX_SESSIONS = 64 in production)
    Ids,           \* logical_id domain a client may (re)use
    Fixed          \* TRUE: terminate relinquishes the id (the fix)

VARIABLES sessions
vars == << sessions >>

Slots == 1..MaxSessions
NoId == "none"
ChildStates == { "none", "running", "zombie" }

Rec(used, alive, child, cp, lid) ==
    [ used |-> used, alive |-> alive, child |-> child,
      close_pending |-> cp, logical_id |-> lid ]

Empty == Rec(0, 0, "none", 0, NoId)

TypeOK ==
    sessions \in [ Slots ->
        [ used : 0..1, alive : 0..1, child : ChildStates,
          close_pending : 0..1, logical_id : Ids \cup {NoId} ] ]

Init == sessions = [ s \in Slots |-> Empty ]

\* ---- helpers -------------------------------------------------------------
HoldsId(s, id)     == sessions[s].used = 1 /\ sessions[s].logical_id = id
AliveHolder(id)    == \E s \in Slots : HoldsId(s, id) /\ sessions[s].alive = 1
AnyHolder(id)      == \E s \in Slots : HoldsId(s, id)
NotAliveHolder(id) == \E s \in Slots : HoldsId(s, id) /\ sessions[s].alive = 0
HasFreeSlot        == \E s \in Slots : sessions[s].used = 0

\* find_logical's reject rule (labpty_registry_open): a NEW open of id is
\* rejected while any used slot still holds it. The fix never changes this
\* rule — it removes the holder, by relinquishing the id at terminate.
OpenBlocked(id) == AnyHolder(id)

\* ---- actions -------------------------------------------------------------
OpenSession(id) ==
    /\ id \in Ids
    /\ ~OpenBlocked(id)
    /\ \E fs \in Slots :
         /\ sessions[fs].used = 0
         /\ sessions' = [ sessions EXCEPT ![fs] = Rec(1, 1, "running", 0, id) ]

\* terminate: enter the async close window. alive drops and close_pending
\* arms. With the fix the logical_id is relinquished immediately (NoId) so it
\* is reusable at once; pre-fix it is retained, so a rapid reopen collides.
Terminate(slot) ==
    /\ sessions[slot].used = 1
    /\ sessions[slot].alive = 1
    /\ sessions' = [ sessions EXCEPT
            ![slot].alive = 0,
            ![slot].close_pending = 1,
            ![slot].logical_id = IF Fixed THEN NoId ELSE sessions[slot].logical_id ]

ChildDies(slot) ==
    /\ sessions[slot].used = 1
    /\ sessions[slot].child = "running"
    /\ sessions' = [ sessions EXCEPT ![slot].child = "zombie" ]

\* reap tick: a close_pending child that has become a zombie is finalised,
\* freeing the slot. This is the EVENTUAL release the old spec proved — but it
\* can lag a client's immediate reopen, which is why reuse must not depend on
\* it.
ReapTick ==
    /\ \E s \in Slots :
            sessions[s].used = 1 /\ sessions[s].close_pending = 1 /\ sessions[s].child = "zombie"
    /\ sessions' = [ s \in Slots |->
            IF sessions[s].used = 1 /\ sessions[s].close_pending = 1 /\ sessions[s].child = "zombie"
            THEN Empty ELSE sessions[s] ]

Next ==
    \/ \E id \in Ids : OpenSession(id)
    \/ \E s \in Slots : Terminate(s)
    \/ \E s \in Slots : ChildDies(s)
    \/ ReapTick

Spec == Init /\ [][Next]_vars

\* ---- invariants ----------------------------------------------------------
FreeSlotIsClean ==
    \A s \in Slots :
        sessions[s].used = 0 =>
            /\ sessions[s].alive = 0
            /\ sessions[s].child = "none"
            /\ sessions[s].close_pending = 0
            /\ sessions[s].logical_id = NoId

ClosePendingImpliesNotAlive ==
    \A s \in Slots : sessions[s].close_pending = 1 => sessions[s].alive = 0

\* Mechanism: a terminated (close_pending) session has relinquished its
\* logical_id, so no not-alive slot ever retains one. Fixed = TRUE holds it;
\* pre-fix violates it (the close_pending slot keeps its id) — and that is the
\* state the SESSION_ID_IN_USE bug needed.
NotAliveImpliesIdRelinquished ==
    \A s \in Slots :
        (sessions[s].used = 1 /\ sessions[s].close_pending = 1)
            => sessions[s].logical_id = NoId

\* Contract: a logical_id held only by not-alive sessions is immediately
\* reusable — open of it is not blocked — when a slot is free. Under the fix
\* this holds because terminate leaves no such holder; pre-fix it is violated.
TerminatedIdIsReusable ==
    \A id \in Ids :
        (NotAliveHolder(id) /\ ~AliveHolder(id) /\ HasFreeSlot) => ~OpenBlocked(id)

=============================================================================
