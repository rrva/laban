-------------------------- MODULE LabptyReuse --------------------------
(****************************************************************************
 The logical_id reuse contract of labpty_registry_open.

 Why this spec exists
   LabptyLifecycle.tla models the slot lifecycle but has NO logical_id, so
   it could only prove that a close_pending slot is EVENTUALLY released
   (EventualReleaseOfClosePending) — not that the id that slot held is
   reusable the instant the session goes not-alive. The integration test
   testRapidOpenTerminateSameLogicalIdSurvives hit exactly that gap: a client
   terminated a logical_id and immediately reopened it, racing the
   asynchronous reap tick, and got SESSION_ID_IN_USE. Fix: commit 389df73 —
   labpty_registry_open now drives a not-alive same-id session's teardown to
   completion synchronously instead of waiting for the next reap tick.

   This module adds the variable the old spec lacked (logical_id) and states
   the property it could not express (TerminatedIdIsReusable). The Fixed
   constant selects the open rule:

     Fixed = TRUE  : the 389df73 behaviour. open rejects only a genuinely
                     ALIVE same-id holder and synchronously reclaims a
                     not-alive one. The invariant holds.
     Fixed = FALSE : the pre-fix behaviour. open rejects ANY same-id holder,
                     including one still in its async close window. TLC finds
                     the terminate->reopen rejection — the negative control
                     (MC_ReusePreFix.cfg), pinning the bug-shape so it cannot
                     silently come back.

   Note the bug is NOT a violation of eventual release: ReapTick still frees
   the slot. The property is about IMMEDIACY — reuse without waiting for a
   tick — which is precisely why a liveness-only model missed it.
 ****************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    MaxSessions,   \* registry slots (LABPTY_MAX_SESSIONS = 64 in production)
    Ids,           \* logical_id domain a client may (re)use
    Fixed          \* TRUE: open reclaims a not-alive same-id slot (389df73)

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

\* find_logical's reject rule. Fixed: only a genuinely ALIVE session blocks
\* reuse. Pre-fix: ANY used slot holding the id blocks it, including one still
\* inside its async close window — the bug.
OpenBlocked(id) == IF Fixed THEN AliveHolder(id) ELSE AnyHolder(id)

\* labpty_session_close on the not-alive same-id slot: SIGKILL-escalates and
\* reaps, leaving the slot Empty. Only reachable under Fixed.
WithSameIdReclaimed(id) ==
    IF Fixed /\ NotAliveHolder(id)
    THEN [ sessions EXCEPT
             ![CHOOSE s \in Slots : HoldsId(s, id) /\ sessions[s].alive = 0] = Empty ]
    ELSE sessions

\* ---- actions -------------------------------------------------------------
OpenSession(id) ==
    /\ id \in Ids
    /\ ~OpenBlocked(id)
    /\ LET base == WithSameIdReclaimed(id) IN
         \E fs \in Slots :
            /\ base[fs].used = 0
            /\ sessions' = [ base EXCEPT ![fs] = Rec(1, 1, "running", 0, id) ]

\* terminate: enter the async close window. alive drops and close_pending
\* arms, but the SIGHUP'd child has not exited yet, so the slot still holds
\* the id — the exact state a rapid reopen collides with.
Terminate(slot) ==
    /\ sessions[slot].used = 1
    /\ sessions[slot].alive = 1
    /\ sessions' = [ sessions EXCEPT
            ![slot].alive = 0, ![slot].close_pending = 1 ]

ChildDies(slot) ==
    /\ sessions[slot].used = 1
    /\ sessions[slot].child = "running"
    /\ sessions' = [ sessions EXCEPT ![slot].child = "zombie" ]

\* reap tick: a close_pending child that has become a zombie is finalised,
\* freeing the slot and its id. This is the EVENTUAL release the old spec
\* proved — but it can lag a client's immediate reopen.
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

\* The property LabptyLifecycle could not state: a logical_id held only by
\* not-alive sessions (terminated, still in their async close window) is
\* immediately reusable — open of it is not blocked — when a slot is free.
\* Fixed = TRUE satisfies it; pre-fix (Fixed = FALSE) violates it, which is
\* the SESSION_ID_IN_USE bug commit 389df73 fixed.
TerminatedIdIsReusable ==
    \A id \in Ids :
        (NotAliveHolder(id) /\ ~AliveHolder(id) /\ HasFreeSlot) => ~OpenBlocked(id)

=============================================================================
